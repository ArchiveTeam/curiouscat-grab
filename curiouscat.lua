dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

local start_urls = JSON:decode(os.getenv("start_urls"))
local items_table = JSON:decode(os.getenv("item_names_table"))
local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false

local discovered_items = {}
local last_main_site_time = 0
local current_item_type = nil
local current_item_value = nil
local next_start_url_index = 1

local current_username = nil

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local do_debug = false
print_debug = function(a)
  if do_debug then
    print(a)
  end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")

local start_urls_inverted = {}
for _, v in pairs(start_urls) do
  start_urls_inverted[v] = true
end

-- Function to be called whenever an item's download ends.
end_of_item = function()
  current_username = nil
end

set_new_item = function(url)
  if url == start_urls[next_start_url_index] then
    end_of_item()
    current_item_type = items_table[next_start_url_index][1]
    current_item_value = items_table[next_start_url_index][2]
    next_start_url_index = next_start_url_index + 1
    print_debug("Setting CIT to " .. current_item_type)
    print_debug("Setting CIV to " .. current_item_value)
  end
  assert(current_item_type)
  assert(current_item_value)

end

discover_item = function(item_type, item_name)
  assert(item_type)
  assert(item_name)

  if not discovered_items[item_type .. ":" .. item_name] then
    print_debug("Queuing for discovery " .. item_type .. ":" .. item_name)
  end
  discovered_items[item_type .. ":" .. item_name] = true
end

add_ignore = function(url)
  if url == nil then -- For recursion
    return
  end
  if downloaded[url] ~= true then
    downloaded[url] = true
  else
    return
  end
  add_ignore(string.gsub(url, "^https", "http", 1))
  add_ignore(string.gsub(url, "^http:", "https:", 1))
  add_ignore(string.match(url, "^ +([^ ]+)"))
  local protocol_and_domain_and_port = string.match(url, "^([a-zA-Z0-9]+://[^/]+)$")
  if protocol_and_domain_and_port then
    add_ignore(protocol_and_domain_and_port .. "/")
  end
  add_ignore(string.match(url, "^(.+)/$"))
end

for ignore in io.open("ignore-list", "r"):lines() do
  add_ignore(ignore)
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

allowed = function(url, parenturl)
  assert(parenturl ~= nil)

  if start_urls_inverted[url] then
    return false
  end

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

  -- Profile page has "force" set on check()
  if string.match(url, "^https?://curiouscat%.live/api/")
    or string.match(url, "^https?://curiouscat%.live/[^/]+/post/[0-9]+$")
    or string.match(url, "^https?://m%.curiouscat%.live/")
    or string.match(url, "^https?://aws%.curiouscat%.me/") -- Replacement for m. ?
    or string.match(url, "^https://media%.tenor%.com/images/") then
    print_debug("allowing " .. url .. " from " .. parenturl)
    return true
  end

  return false

  --return false

  --assert(false, "This segment should not be reachable")
end



wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  --print_debug("DCP on " .. url)
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    --set_derived_url(url)
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    assert(not force or force == true) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    -- url_ = string.match(url_, "^(.-)/?$") # Breaks dl.
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl) or force) then
      table.insert(urls, { url=url_, headers={["Accept-Language"]="en-US,en;q=0.5"}})
      --set_derived_url(url_)
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    -- Being caused to fail by a recursive call on "../"
    if not newurl then
      return
    end
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, "/" .. newurl))
    end
  end

  local function load_html()
    if html == nil then
      html = read_file(file)
    end
    return html
  end

  if current_item_type == "userid" then
    -- New starting point
    if string.match(url, "^https?://curiouscat%.live/api/v2%.1/get_profile_userData%?userID=") then
      local json = JSON:decode(load_html())
      if json["error"] == "404" or json["error"] == 404 then
        print("ID -> profile req indicates user does not exist")
      else
        current_username = json["userData"]["username"]
        check("https://curiouscat.live/" .. current_username, true)
      end
    end
    
    if string.match(url, "https?://curiouscat%.live/[^/]+$") and status_code == 200 then
      assert(string.match(load_html(), "<title>CuriousCat</title><link")) -- To make sure it's still up
      check("https://curiouscat.live/api/v2.1/profile?username=" .. current_username .. "&_ob=registerOrSignin2")
      check("https://curiouscat.live/api/v2/ad/check?path=/" .. current_username .. "&_ob=registerOrSignin2")
    end

    if string.match(url, "^https?://curiouscat%.live/api/v2%.1/profile%?") and status_code == 200 then
        print_debug("API on " .. url)
        local json = JSON:decode(load_html())
        if json["error"] == 404 then
          error("This should not happen anymore")
        else
          assert(json["error"] == nil, "error unacceptable: " .. JSON:encode(json["error"]))
          local lowest_ts = 100000000000000
          for _, post in pairs(json["posts"]) do
            local content_block = nil
            local time = nil
            if post["type"] == "post" then
              content_block = post["post"]
              time = post["post"]["timestamp"]
            elseif post["type"] == "status" then
              content_block = post["status"]
              time = post["status"]["timestamp"]
            elseif post["type"] == "shared_post" then
              content_block = post["post"]
              time = post["shared_timestamp"]
            else
              error("Unknown post type " .. post["type"])
            end

            if content_block then
              check((content_block["addresseeData"] or content_block["author"])["avatar"])
              check((content_block["addresseeData"] or content_block["author"])["banner"])

              if content_block["media"] then
                assert(allowed(content_block["media"]["img"], url), content_block["media"]["img"]) -- Don't just want to silently discard this on a failed assumption
                check(content_block["media"]["img"])
              end

              assert(content_block["likes"])
              if content_block["likes"] > 0 then
                check("https://curiouscat.live/api/v2/post/likes?postid=" .. tostring(content_block["id"]) .. "&_ob=registerOrSignin2")
              end

              -- Remove this block if the project looks uncertain
              if post["type"] ~= "shared_post" then
                check("https://curiouscat.live/" .. current_username .. "/post/" .. tostring(content_block["id"]))
                check("https://curiouscat.live/api/v2.1/profile/single_post?username=" .. current_username .. "&post_id=" .. tostring(content_block["id"]) .. "&_ob=registerOrSignin2")
                check("https://curiouscat.live/api/v2/ad/check?path=/" .. current_username .. "/post/" .. tostring(content_block["id"]) .. "&_ob=registerOrSignin2")
              end
            end

            if time and time < lowest_ts then
                lowest_ts = time
              end
          end


          if lowest_ts == 100000000000000 then
            assert(not string.match(url, "&max_timestamp=")) -- Something is wrong if we get an empty on a page other than the first
          else
            check("https://curiouscat.live/api/v2.1/profile?username=" .. current_username .. "&max_timestamp=" .. tostring(lowest_ts) .. "&_ob=registerOrSignin2") -- Following Jodizzle's scheme, this just uses the queued URLs as a set, and "detects" the last page by the fact that the lowest is it itself
          end
        end
    end
  end


  if status_code == 200 and not (string.match(url, "%.jpe?g$") or string.match(url, "%.png$")) then
    -- Completely disabled because I can't be bothered
    --[[load_html()

    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end]]
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  assert(not (string.match(url["url"], "^https?://[^/]*google%.com/sorry") or string.match(url["url"], "^https?://consent%.google%.com/")))

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end

    --[[
  -- Handle redirects not in download chains
  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    print_debug("newloc is " .. newloc)
    if downloaded[newloc] == true or addedtolist[newloc] == true then
      tries = 0
      print_debug("Already encountered newloc " .. newloc)
      tries = 0
      return wget.actions.EXIT
    elseif not allowed(newloc, url["url"]) then
      print_debug("Disallowed URL " .. newloc)
      -- Continue on to the retry cycle
    else
      tries = 0
      print_debug("Following redirect to " .. newloc)
      assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/")))
      assert(not string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$")) -- If this is a redirect, it will mess up initialization of file: items
      assert(not string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$")) -- Likewise for folder:

      addedtolist[newloc] = true
      return wget.actions.NOTHING
    end
  end]]

  local do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Whitelist instead of blacklist status codes
  if status_code ~= 200 then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end

  -- Check for rate limiting in the API (status code == 200)
  if string.match(url["url"], "^https?://curiouscat%.live/api/") then
    if string.match(read_file(http_stat["local_file"]), "^{'error': 'Wait") then
      print("API rate-limited, sleeping")
      do_retry = true
    end
  end

  if do_retry then
    if tries >= maxtries then
      print("I give up...\n")
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end

  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s").
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


queue_list_to = function(list, key)
  if do_debug then
    for item, _ in pairs(list) do
      print("Would have sent discovered item " .. item)
    end
  else
    local to_send = nil
    for item, _ in pairs(list) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      if to_send == nil then
        to_send = item
      else
        to_send = to_send .. "\0" .. item
      end
      print("Queued " .. item)
    end

    if to_send ~= nil then
      local tries = 0
      while tries < 10 do
        local body, code, headers, status = http.request(
          "http://blackbird-amqp.meo.ws:23038/" .. key .. "/",
          to_send
        )
        if code == 200 or code == 409 then
          break
        end
        os.execute("sleep " .. math.floor(math.pow(2, tries)))
        tries = tries + 1
      end
      if tries == 10 then
        abortgrab = true
      end
    end
  end
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  end_of_item()
end

wget.callbacks.write_to_warc = function(url, http_stat)
  set_new_item(url["url"])
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

