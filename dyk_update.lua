--[[
Author: Alexander Misel
Original python code: https://github.com/liangent/updatedyk/blob/master/updatedyk.py
]]
local MediaWikiApi = require('mwtest/mwapi')
local Utils = require('mwtest/utils')
local socket = require('socket')
local sha1 = require('sha1')

local MAX_UPDATES = 3

--local json = require('rapidjson')
--MediaWikiApi.done_pages = json.decode([[json_dump]])

function normalizeTpl(tpl_str)
  local template = {}
  for line in tpl_str:gmatch('[^\n]+') do
    local attr, value = line:match('^ *| *(%w+) *= *(.-) *$')
    if attr then
      template[attr] = value
    end
  end
  return template
end

function generateTpl(template, ordering)
  local tpl_str = ''
  if ordering then
    for _, v in ipairs(ordering) do
      tpl_str = tpl_str .. '\n | ' .. v .. ' = ' .. (template[v] or '')
    end
  else
    for k, v in pairs(template) do
      tpl_str = tpl_str .. '\n | ' .. k .. ' = ' .. (v or '')
    end
  end
  return tpl_str
end

function processDykEntry(content)
  local start, tpl_str, final = content:match('{{ ?Dyk/auto()(.-)()\n}}')
  local dyk_tpl = normalizeTpl(tpl_str)
  local entries = {}
  local questions = {}
  for i = 1, 6 do
    local question = dyk_tpl[tostring(i-1)]
    table.insert(entries, {
      question = question,
      image = dyk_tpl['p' .. (i-1)],
      type = dyk_tpl['t' .. (i-1)]
    })
    questions[question] = true
  end
  return entries, questions, start, final
end

function updateDyk(entries, content, start, final)
  local new_entries = {}
  
  for i = 1, 6 do
    new_entries[tostring(i-1)] = entries[i].question
    new_entries['p' .. (i-1)] = entries[i].image
    new_entries['t' .. (i-1)] = entries[i].type
  end
  
  new_entries.allimages = '{{{allimages|no}}}'
  
  local tpl_order = { '0', 'p0', 't0', '1', 'p1', 't1', '2', 'p2', 't2', 
    '3', 'p3', 't3', '4', 'p4', 't4', '5', 'p5', 't5', 'allimages' }
  return content:sub(1, start-1) .. generateTpl(new_entries, tpl_order) .. content:sub(final)
end

function processDykcEntry(entry_str)
  local entry = normalizeTpl(entry_str)

  if not entry.hash then
    return sha1.sha1(entry.question), entry.timestamp
  end
  if not entry.result then
    return nil, entry.timestamp
  end
  local result, timestamp = entry.result:match('^(.-)|.-|(.-)$')
  if timestamp == '0' then
    return nil, entry.timestamp
  end

  if result and timestamp then
    local jsonres = MediaWikiApi.performRequest {
      action = 'query',
      prop = 'revisions',
      titles = 'Wikipedia:新条目推荐/候选',
      rvlimit = 1,
      rvprop = 'user|comment',
      rvdir = 'newer',
      rvstart = timestamp - 1,
      rvend = timestamp,
      format = 'json',
      formatversion = 2
    }
    if not jsonres.query.pages[1].revisions then
      MediaWikiApi.trace('Bad timestamp!')
      return nil, entry.timestamp
    end
    local user = jsonres.query.pages[1].revisions[1].user
    
    -- closed by admin
    jsonres = MediaWikiApi.performRequest {
      action = 'query',
      list = 'users',
      ususers = user,
      usprop = 'groups',
      format = 'json'
    }
    if not Utils.hasValue(jsonres.query.users[1].groups, 'sysop') then
      MediaWikiApi.trace('User:' .. user .. ' doesn\'t have sysop access!')
      return nil, entry.timestamp
    end
    
    -- lowercase the type
    entry.type = entry.type and entry.type:lower()
    
    if result == '+' or result == '*' then
      return true, entry
    else
      return false, entry
    end
  else
    return nil, entry.timestamp
  end
end

function getNewDykResult(old_entries, typeTable, entries)
  local actual_updates = MAX_UPDATES
  local compli_entries = Utils.subrange(old_entries, 1, 6-actual_updates)
  local entries_len = #entries
  for i=1, 6-actual_updates do
    local oentry_type = compli_entries[i].type
    local entry_id = typeTable[oentry_type]
    if entry_id then
      typeTable[oentry_type] = nil
      entries_len = entries_len - 1
    end
  end
  local checked_last = 6 - actual_updates
  if entries_len >= actual_updates then
    local filtered_entries = table.filter(entries, function(x)
      return typeTable[x.entry.type]
    end)
    return table.reverse(Utils.subrange(filtered_entries, 1, actual_updates)), compli_entries
  end
  actual_updates = entries_len
  compli_entries = Utils.subrange(old_entries, 1, 6-actual_updates)
  
  while actual_updates > 0 do
    local full = true
    local new_compli_len = #compli_entries
    for i=checked_last+1, new_compli_len do
      local oentry_type = compli_entries[i].type
      local entry_id = typeTable[oentry_type]
      if entry_id then
        typeTable[oentry_type] = nil
        actual_updates = actual_updates - 1
        compli_entries[6-actual_updates] = entries[6-actual_updates]
        full = false
      end
    end
    
    if full then
      return table.reverse(table.filter(entries, function(x)
        return typeTable[x.entry.type]
      end)), compli_entries
    else
      checked_last = new_compli_len
    end
  end
end

function archivePassedArticles(the_entry, revid, dykc_tpl, dykc_tail)
  local art_name = the_entry.article
  local done_log = MediaWikiApi.done_pages[art_name]
  if done_log then
    if done_log.complete then return end
  else
    MediaWikiApi.done_pages[art_name] = {}
    done_log = MediaWikiApi.done_pages[art_name]
  end

  -- purge mainpage?
  if not done_log.talk then
    MediaWikiApi.trace('Archive talk page of ' .. art_name)
    updateTalkPage(art_name, revid, dykc_tpl, dykc_tail)
    done_log.talk = true
  end
  if (the_entry.author and the_entry.author ~= '') and not done_log.upage then
    local upage_title = 'User:' .. the_entry.author
    local upage = MediaWikiApi.getCurrent(upage_title)
    if upage then -- if no userpage, don't try to create
      upage = upage.content
      local foundTpl = false
      upage = upage:gsub('{{produceEncouragement|count=(%d+)}}', function (s)
        foundTpl = true
        return '{{produceEncouragement|count=' .. (tonumber(s)+1) ..'}}'
      end, 1)
      if foundTpl then
        MediaWikiApi.edit(upage_title, upage)
      else
        MediaWikiApi.editPend(upage_title, '{{produceEncouragement|count=1}}', nil, true)
      end
    end
    done_log.upage = true
  end

  done_log.complete = true
end

function updateTalkPage(article, id, dykc_tpl, dykc_tail, failed)
  local talk_title = 'Talk:' .. article
  local talk_page = MediaWikiApi.getCurrent(talk_title)
  talkpage_cont = talk_page and talk_page.content or ''
  talkpage_cont = talkpage_cont:gsub('{{ ?DYK ?[Ii]nvite%s-}}\n?', '')
  local talk_new = failed and '' or os.date('!{{DYKtalk|%Y年|%m月%d日}}\n'):gsub('0(%d[月日])', '%1')
  if #talkpage_cont then
    talk_new = talk_new .. talkpage_cont
  end
  
  local additional_params = { revid = id, closets = '{{subst:#time:U}}' }
  if failed then
    additional_params.rejected = 'rejected'
  end
  talk_new = talk_new .. ('\n\n{{ DYKEntry/archive' .. dykc_tpl ..
    generateTpl(additional_params) .. '\n}}' .. dykc_tail)
  MediaWikiApi.edit(talk_title, talk_new)
end

function concatTimedEntries(new_list)
  local result_str = ''
  for k, v in ipairs(new_list) do
    if not v.removed then
      if v.timestamp then
        if k == 1 then
          result_str = result_str .. os.date('!\n=== %m月%d日 ===', v.timestamp):gsub('0(%d[月日])', '%1')
        elseif new_list[k-1].timestamp then
          if os.date('!%d', new_list[k-1].timestamp) ~= os.date('!%d', v.timestamp) then
            result_str = result_str .. os.date('!\n=== %m月%d日 ===', v.timestamp):gsub('0(%d[月日])', '%1')
          end
        end
      end
      result_str = result_str .. '\n==== ====' .. v.entry
    end
  end
  return result_str
end

function hashRemoval(hash_dict)
  MediaWikiApi.base_time = os.time()

  local dykc_page = MediaWikiApi.getCurrent('Wikipedia:新条目推荐/候选')
  local dykc_list = dykc_page.content:split('\n{{ ?DYKEntry')
  local dykc_head = table.remove(dykc_list, 1):gsub('\n=[^\n]-月[^\n]-日[^\n]-=\n', '\n'):gsub('\n=[^\n]+=%s-$', '')
  for k = 1, #dykc_list do
    dykc_list[k] = '\n{{ DYKEntry' .. dykc_list[k]
  end
  local dykc_final = table.remove(dykc_list)
  local new_dykc_list = {}
  
  for i = 1, #dykc_list do
    local clear_entry = dykc_list[i]
    local dykc_tpl, dykc_tail = clear_entry:match('^\n{{ DYKEntry(.-)\n}}(.*)$')
    if i == #dykc_list then
        local newsec = dykc_tail:match('\n=[^\n]+=%s-$')
        dykc_final = (newsec or '') .. dykc_final
      end
    old_tail_len = #dykc_tail
    dykc_tail = dykc_tail:gsub('\n=.+=%s-$', '')
    dykc_list[i] = dykc_list[i]:sub(1, #dykc_list[i] - old_tail_len) .. dykc_tail

    local parsedEntry = normalizeTpl(dykc_tpl)
    if not (parsedEntry.hash and hash_dict[parsedEntry.hash]) then
      table.insert(new_dykc_list, {
        entry = dykc_list[i],
        timestamp = tonumber(parsedEntry.timestamp)
      })
    end
  end
  
  if not pcall(function ()
    MediaWikiApi.edit('Wikipedia:新条目推荐/候选', dykc_head .. concatTimedEntries(new_dykc_list) .. dykc_final)
  end) then
    MediaWikiApi.trace('Save failed. Try again...')
    hashRemoval(hash_dict)
  end
end

function mainTask()
  MediaWikiApi.base_time = os.time()

  local dykc_page = MediaWikiApi.getCurrent('Wikipedia:新条目推荐/候选')
  local dyk = MediaWikiApi.getCurrent('Template:Dyk')
  local archive_title = 'Wikipedia:新条目推荐/' .. os.date('!%Y年%m月'):gsub('0(%d[月日])', '%1')
  local archive = MediaWikiApi.getCurrent(archive_title)
  if not archive then
    MediaWikiApi.edit(archive_title, '{{DYKMonthlyArchive}}')
  end

  local dykc_list = dykc_page.content:split('\n{{ ?DYKEntry')
  local dykc_head = table.remove(dykc_list, 1):gsub('\n=[^\n]-月[^\n]-日[^\n]-=\n', '\n'):gsub('\n=[^\n]+=%s-$', '')
  for k = 1, #dykc_list do
    dykc_list[k] = '\n{{ DYKEntry' .. dykc_list[k]
  end
  local dykc_final = table.remove(dykc_list)

  local delta_hours = 6

  local recent_time = Utils.getTime(dyk.timestamp)

  if os.difftime(os.time(), recent_time) > delta_hours * 3600 then
    local new_dykc_list = {}

    local dyk_cont = dyk.content
    local dyk_entries, dyk_ques, dyk_start, dyk_end = processDykEntry(dyk_cont)
    
    -- new dyk related
    local typeTable = {}
    local new_dyk_entries = {}
    
    local remove_hash = {}
    
    for i = #dykc_list, 1, -1 do
      local dykc_tpl, dykc_tail = dykc_list[i]:match('^\n{{ DYKEntry(.-)\n}}(.*)$')
      if i == #dykc_list then
        local newsec = dykc_tail:match('\n=[^\n]+=%s-$')
        dykc_final = (newsec or '') .. dykc_final
      end
      old_tail_len = #dykc_tail
      dykc_tail = dykc_tail:gsub('\n=.+=%s-$', '')
      dykc_list[i] = dykc_list[i]:sub(1, #dykc_list[i] - old_tail_len) .. dykc_tail
      
      local res, parsedEntry = processDykcEntry(dykc_tpl)
      if res == false then
        MediaWikiApi.trace('Archive failed candidate ' .. parsedEntry.article)
        MediaWikiApi.editPend('Wikipedia:新条目推荐/未通过/' .. os.date('!%Y年'), '\n* ' .. parsedEntry.question) -- append
        MediaWikiApi.trace('Archive talk page of ' .. parsedEntry.article)
        artpage = MediaWikiApi.getCurrent(parsedEntry.article)
        if artpage then
          updateTalkPage(parsedEntry.article, dykc_page.revid, dykc_tpl, dykc_tail, true)
        else -- when article is deleted
          local additional_params = { revid = dykc_page.revid, closets = '{{subst:#time:U}}', rejected = 'rejected' }
          local talk_new = '\n\n{{ DYKEntry/archive' .. dykc_tpl .. generateTpl(additional_params) .. '\n}}'
          MediaWikiApi.editPend('Wikipedia talk:新条目推荐/未通过/' .. os.date('!%Y年'), talk_new) -- append
        end
        remove_hash[parsedEntry.hash] = true
      else
        local new_list_index = #new_dykc_list + 1
        local new_list_item = {
          entry = dykc_list[i],
          timestamp = tonumber(parsedEntry)
        }
        if res then
          if res == true then
            new_list_item.timestamp = tonumber(parsedEntry.timestamp)
            if dyk_ques[parsedEntry.question] then
              archivePassedArticles(parsedEntry, dykc_page.revid, dykc_tpl, dykc_tail)
              new_list_item.removed = true
              remove_hash[parsedEntry.hash] = true
            elseif not typeTable[parsedEntry.type] then
              local new_dyk_index = #new_dyk_entries + 1
              typeTable[parsedEntry.type] = new_dyk_index
              new_dyk_entries[new_dyk_index] = {
                entry = parsedEntry,
                index = new_list_index,
                dykc_tpl = dykc_tpl,
                dykc_tail = dykc_tail
              }
            end
          else
            new_list_item.entry = new_list_item.entry:gsub('\n}}',
              generateTpl({ hash = res, result = '' }, { 'hash', 'result' }) .. '\n}}', 1)
          end
        end
        new_dykc_list[new_list_index] = new_list_item
      end
    end
    
    local update_ones, old_ones = getNewDykResult(dyk_entries, typeTable, new_dyk_entries)
    -- check if we need to update the dyk
    if update_ones then
      local archive_str = ''
      for i, v in ipairs(update_ones) do
        remove_hash[v.entry.hash] = true
        new_dykc_list[v.index].removed = true
        archive_str = archive_str .. ('* ' .. v.entry.question .. '\n')
      end
      MediaWikiApi.trace('Archiving')
      MediaWikiApi.editPend('Wikipedia:新条目推荐/存档/' .. os.date('!%Y年%m月'):gsub('0(%d[月日])', '%1'),
                            archive_str, nil, true)
      MediaWikiApi.editPend('Wikipedia:新条目推荐/供稿/' .. os.date('!%Y年%m月%d日'):gsub('0(%d[月日])', '%1'),
                            archive_str, nil, true)
      dyk_entries = Utils.tableConcat(table.map(update_ones, function(x)
        archivePassedArticles(x.entry, dykc_page.revid, x.dykc_tpl, x.dykc_tail)
        return x.entry
      end), old_ones)
      
      MediaWikiApi.trace('Updating DYK page')
      MediaWikiApi.edit('Template:Dyk', updateDyk(dyk_entries, dyk_cont, dyk_start, dyk_end))
    end
    
    MediaWikiApi.trace('Updating DYKC page')
    if not pcall(function ()
      MediaWikiApi.edit('Wikipedia:新条目推荐/候选', dykc_head .. concatTimedEntries(table.reverse(new_dykc_list)) .. dykc_final)
    end) then
      MediaWikiApi.trace('Save failed. Try again...')
      hashRemoval(remove_hash)
    end
  end
end

function runner()
  pcall(mainTask)
  MediaWikiApi.edit_token = nil
  MediaWikiApi.trace('Sleep one hour')
  socket.sleep(3600)
  runner()
end

-- MediaWikiApi.login('username', 'password')
-- runner()
mainTask()
