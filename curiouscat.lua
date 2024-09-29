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

local current_item_value_proper_capitalization = nil
local do_retry = false -- read by get_urls


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
	current_item_value_proper_capitalization = nil
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
  -- Assert that if the page (or something in the script, erroneously) is giving us an alternate form with different capitalization, there is only one form
  if string.lower(item_name) == string.lower(current_item_value) and item_name ~= current_item_value then
    if current_item_value_proper_capitalization ~= nil then
      assert(current_item_value_proper_capitalization == item_name)
    else
      current_item_value_proper_capitalization = item_name
    end
  end

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

  if string.match(url, "^https?://curiouscat%.live/api/") -- Do not allow the initial pages, instead only let them in through the wget args
    or string.match(url, "^https?://curiouscat%.live/[^/]+/post/[0-9]+$")
    or string.match(url, "^https?://m%.curiouscat%.live/")
    or string.match(url, "^https?://aws%.curiouscat%.me/") -- Replacement for m. ?
    or string.match(url, "^https://media%.tenor%.com/images/")
    or string.match(url, "^https?://curiouscat%.me/") then
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
  
  -- See onboardingAB.js - this which of these 2 options is used is determined by a random number
  local function check_ob(urla, force)
    check(urla .. "&_ob=registerOrSignin2", force)
    check(urla .. "&_ob=noregisterOrSignin2", force)
  end
  
  local function assert_avatar_or_banner(urla)
    assert(urla:match("^https://aws%.curiouscat%.me/%d+/avatars/%d+%.jpg$") or urla:match("^https://aws%.curiouscat%.me/%d+/banners/%d+%.jpg$"))
  end

  if current_item_type == "user" then
    -- Starting point
    if string.match(url, "https?://curiouscat%.live/[^/]+$") and status_code == 200 then
      assert(string.match(load_html(), "<title>CuriousCat</title><link")) -- To make sure it's still up
      check_ob("https://curiouscat.live/api/v2.1/profile?username=" .. current_item_value)
      check_ob("https://curiouscat.live/api/v2/ad/check?path=/" .. current_item_value)
      check((url:gsub("^https?://curiouscat%.live/", "https://curiouscat.me/"))) -- Get the redirect
    end

    if string.match(url, "^https?://curiouscat%.live/api/v2%.1/profile%?") and status_code == 200 then
        print_debug("API on " .. url)
        local json = JSON:decode(load_html())
        if json["error"] == 404 then
          print_debug("Profile req indicates user does not exist")
        elseif json["error"] then
          assert(do_retry)
        else
          assert(json["error"] == nil, "error unacceptable: " .. JSON:encode(json["error"]))
          assert_avatar_or_banner(json["avatar"])
          assert_avatar_or_banner(json["banner"])
          check(json["avatar"])
          check(json["banner"])
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
              print("Status type found on user " .. current_item_value) -- Trying to find a replacement for user:tetekoobsf, which is gigantic, in the tests
            elseif post["type"] == "shared_post" then
              discover_item("user", post["post"]["addresseeData"]["username"])
              content_block = post["post"]
              time = post["shared_timestamp"]
            else
              error("Unknown post type " .. post["type"])
            end

            if content_block then
              check((content_block["addresseeData"] or content_block["author"])["avatar"])
              check((content_block["addresseeData"] or content_block["author"])["banner"])

              if content_block["senderData"] and content_block["senderData"]["username"] then
                discover_item("user", content_block["senderData"]["username"])
              end
              
              if content_block["media"] then
                assert(allowed(content_block["media"]["img"], url), content_block["media"]["img"]) -- Don't just want to silently discard this on a failed assumption
                check(content_block["media"]["img"])
              end
              

              assert(content_block["likes"])
              if content_block["likes"] > 0 then
                discover_item("postlikes", content_block["id"])
              end

              -- Remove this block if the project looks uncertain
              if post["type"] ~= "shared_post" then
                check("https://curiouscat.live/" .. current_item_value .. "/post/" .. tostring(content_block["id"]))
                check_ob("https://curiouscat.live/api/v2.1/profile/single_post?username=" .. current_item_value .. "&post_id=" .. tostring(content_block["id"]))
                check_ob("https://curiouscat.live/api/v2/ad/check?path=/" .. current_item_value .. "/post/" .. tostring(content_block["id"]))
              end
            end

            if time and time < lowest_ts then
                lowest_ts = time
              end
          end


          if lowest_ts == 100000000000000 then
            assert(not string.match(url, "&max_timestamp=")) -- Something is wrong if we get an empty on a page other than the first
          else
            check_ob("https://curiouscat.live/api/v2.1/profile?username=" .. current_item_value .. "&max_timestamp=" .. tostring(lowest_ts)) -- Following Jodizzle's scheme, this just uses the queued URLs as a set, and "detects" the last page by the fact that the lowest is it itself
          end
          
          
          -- Get the first page of followers/following
          assert((json["following_count"] == nil) == (json["followers_count"] == nil))
          if json["following_count"] then
            check_ob("https://curiouscat.live/api/v2/profile/followers?username=" .. current_item_value)
            check_ob("https://curiouscat.live/api/v2/profile/following?username=" .. current_item_value)
          end
        end
    end
    
    if string.match(url, "^https?://curiouscat%.live/api/v2/profile/follow") and status_code == 200 then -- followers and following
      local json = JSON:decode(load_html())
      
      if json["error"] then
        assert(do_retry)
      else
        for _, relation in pairs(json["result"]) do
          discover_item("user", relation["username"])
        end
        
        if #json["result"] > 0 then
          check_ob("https://curiouscat.live/api/v2/" .. json["paging"]["next"])
          assert(json["paging"]["next"]:gmatch(json["paging"]["next_cursor"]))
        end
      end
    end
  end

  if current_item_type == "postlikes" then
    if string.match(url, "^https?://curiouscat%.live/api/v2/post/likes") and status_code == 200 then
      local json = JSON:decode(load_html())
      if not json["error"] then
        check((url:gsub("_ob=registerOrSignin2", "_ob=noregisterOrSignin2")))
        for _, obj in pairs(json["users"]) do
          discover_item("user", obj["username"])
        end
      elseif json["error"] ~= "No likes" then
        assert(do_retry)
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
  
  
  do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Whitelist instead of blacklist status codes
  if status_code ~= 200
    and not (url["url"]:match("^https?://curiouscat.me/") and status_code == 302) then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end

  -- Check for rate limiting in the API (status code == 200)
  if string.match(url["url"], "^https?://curiouscat%.live/api/") then
    local json = JSON:decode(read_file(http_stat["local_file"]))
    if json["error"] == "Wait a bit" then
      print("API rate-limited, sleeping")
      do_retry = true
    elseif json["error"] == 404 then
      print_debug("HLS 404")
    elseif json["error"] == "No likes" then
      print_debug("HLS no likes")
    elseif json["error"] then
      error("Unknown error in response (dumping) " .. read_file(http_stat["local_file"]))
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
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


local send_binary = function(to_send, key)
  local tries = 0
  while tries < 10 do
    local body, code, headers, status = http.request(
            "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
            to_send
    )
    if code == 200 or code == 409 then
      break
    end
    print("Failed to submit discovered URLs." .. tostring(code) .. " " .. tostring(body)) -- From arkiver https://github.com/ArchiveTeam/vlive-grab/blob/master/vlive.lua
    os.execute("sleep " .. math.floor(math.pow(2, tries)))
    tries = tries + 1
  end
  if tries == 10 then
    abortgrab = true
  end
end

-- Taken verbatim from previous projects I've done'
local queue_list_to = function(list, key)
  assert(key)
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

      if #to_send > 1500 then
        send_binary(to_send .. "\0", key)
        to_send = ""
      end
    end

    if to_send ~= nil and #to_send > 0 then
      send_binary(to_send .. "\0", key)
    end
  end
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  end_of_item()
  queue_list_to(discovered_items, "curiouscat-ijxdk4ufz59tw83")
end

wget.callbacks.write_to_warc = function(url, http_stat)
  if string.match(url["url"], "^https?://curiouscat%.live/api/") then
    local json = JSON:decode(read_file(http_stat["local_file"]))
    if json["error"] and json["error"] ~= 404 and json["error"] ~= "No likes" then
      return false
    end
  end
  set_new_item(url["url"])
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

