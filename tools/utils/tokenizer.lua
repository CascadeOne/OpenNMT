local tokenizer = {}

local unicode = require('tools.utils.unicode')
local case = require ('tools.utils.case')
local separators = require('tools.utils.separators')
local alphabet = require('tools.utils.alphabets')

local alphabet_list = {}
for k,_ in pairs(alphabet.ranges) do
  table.insert(alphabet_list, k)
end

local options = {
  {
    '-mode', 'conservative',
    [[Define how aggressive should the tokenization be. `aggressive` only keeps sequences
      of letters/numbers, `conservative` allows a mix of alphanumeric as in: "2,000", "E65",
      "soft-landing", etc. `space` is doing space tokenization.]],
    {
      enum = {'space', 'conservative', 'aggressive'}
    }
  },
  {
    '-joiner_annotate', false,
    [[Include joiner annotation using `-joiner` character.]]
  },
  {
    '-joiner', separators.joiner_marker,
    [[Character used to annotate joiners.]]
  },
  {
    '-joiner_new', false,
    [[In `-joiner_annotate` mode, `-joiner` is an independent token.]]
  },
  {
    '-case_feature', false,
    [[Generate case feature.]]
  },
  {
    '-segment_case', false,
    [[Segment case feature, splits AbC to Ab C to be able to restore case]]
  },
  {
    '-segment_alphabet', {},
    [[Segment all letters from indicated alphabet.]],
    {
      enum = alphabet_list,
    }
  },
  {
    '-segment_numbers', false,
    [[Segment numbers into single digits.]]
  },
  {
    '-segment_alphabet_change', false,
    [[Segment if alphabet change between 2 letters.]]
  },
  {
    '-bpe_model', '',
    [[Apply Byte Pair Encoding if the BPE model path is given. If the option is used,
      BPE related options will be overridden/set automatically if the BPE model specified by `-bpe_model`
      is learnt using `learn_bpe.lua`.]]
  },
  {
    '-bpe_EOT_marker', separators.EOT,
    [[Marker used to mark the End of Token while applying BPE in mode 'prefix' or 'both'.]]
  },
  {
    '-bpe_BOT_marker', separators.BOT,
    [[Marker used to mark the Beginning of Token while applying BPE in mode 'suffix' or 'both'.]]
  },
  {
    '-bpe_case_insensitive', false,
    [[Apply BPE internally in lowercase, but still output the truecase units.
      This option will be overridden/set automatically if the BPE model specified by `-bpe_model`
      is learnt using `learn_bpe.lua`.]]
  },
  {
    '-bpe_mode', 'suffix',
    [[Define the BPE mode. This option will be overridden/set automatically if the BPE model
      specified by `-bpe_model` is learnt using `learn_bpe.lua`. `prefix`: append `-bpe_BOT_marker`
      to the begining of each word to learn prefix-oriented pair statistics;
      `suffix`: append `-bpe_EOT_marker` to the end of each word to learn suffix-oriented pair
      statistics, as in the original Python script; `both`: `suffix` and `prefix`; `none`:
      no `suffix` nor `prefix`.]],
    {
      enum = {'suffix', 'prefix', 'both', 'none'}
    }
  }
}

function tokenizer.getOpts()
  return options
end

function tokenizer.declareOpts(cmd)
  cmd:setCmdLineOptions(options, 'Tokenizer')
end

local function inTable(v, t)
  for _, vt in ipairs(t or {}) do
    if v == vt then
      return true
    end
  end
  return false
end

-- minimalistic tokenization
-- - remove utf-8 BOM character
-- - turn sequences of separators into single space
-- - skip any other non control character [U+0001-U+002F]
-- - keep sequence of letters/numbers and tokenize everything else
local function tokenize(line, opt)
  if opt.mode == 'space' then
    local index = 1
    local tokens = {}
    while index <= line:len() do
      local sepStart, sepEnd = line:find(' ', index)
      local sub
      if not sepStart then
        sub = line:sub(index)
        if sub ~= '' then
          table.insert(tokens, sub)
        end
        break
      else
        sub = line:sub(index, sepStart - 1)
        if sub ~= '' then
          table.insert(tokens, sub)
        end
        index = sepEnd + 1
      end
    end

    return tokens
  end

  local tokens = {}
  -- contains the current token
  local curtok = ''
  -- keep category of the previous character
  local space = true
  local letter = false
  local prev_alphabet
  local number = false
  local other = false
  local placeholder = false

  -- iterate on utf-8 characters
  for v, c, nextv in unicode.utf8_iter(line) do
    if placeholder then
      if c == separators.ph_marker_close then
        curtok = curtok .. c
        letter = true
        prev_alphabet = 'placeholder'
        placeholder = false
        space = false
      else
        if unicode.isSeparator(v) then
          c = string.format(separators.protected_character.."%04x", v)
        end
        curtok = curtok .. c
      end
    elseif c == separators.ph_marker_open then
      local initc = ''
      if space == false then
        if opt.joiner_annotate and not(opt.joiner_new) then
          if (letter and prev_alphabet ~= 'placeholder') or number then
            initc = opt.joiner
          else
            curtok = curtok .. opt.joiner
          end
        end
        table.insert(tokens, curtok)
        curtok = initc
        if opt.joiner_annotate and opt.joiner_new then
          table.insert(tokens, opt.joiner)
        end
      elseif other == true then
        if opt.joiner_annotate then
          if curtok == '' then
            if opt.joiner_new then table.insert(tokens, opt.joiner)
            else tokens[#tokens] = tokens[#tokens] .. opt.joiner end
          end
        end
      end
      curtok = curtok .. c
      placeholder = true
    elseif unicode.isSeparator(v) then
      if space == false then
        table.insert(tokens, curtok)
        curtok = ''
      end
      -- if the character is the ZERO-WIDTH JOINER character (ZWJ), add joiner
      if v == 0x200D then
        if opt.joiner_annotate and opt.joiner_new and #tokens then
          table.insert(tokens, opt.joiner)
        elseif opt.joiner_annotate then
          if other or (number and unicode.isLetter(nextv)) then
            tokens[#tokens] = tokens[#tokens] .. opt.joiner
          else
            curtok = opt.joiner
          end
        end
      end
      number = false
      letter = false
      space = true
      other = false
    else
      -- skip special characters and BOM
      if v > 32 and not(v == 0xFEFF) then
        -- normalize the separator marker and feat separator
        if separators.substitutes[c] then
          c = separators.substitutes[c]
        end

        local is_letter = unicode.isLetter(v)
        local is_alphabet
        if is_letter and (opt.segment_alphabet_change or (opt.segment_alphabet and #opt.segment_alphabet>0)) then
          is_alphabet = alphabet.findAlphabet(v)
        end

        local is_number = unicode.isNumber(v)
        local is_mark = unicode.isMark(v)
        -- if we have a mark, we keep type of previous character
        if is_mark then
          is_letter = letter
          is_number = number
        end
        if opt.mode == 'conservative' then
          if is_number or (c == '-' and letter == true) or c == '_' or
                (letter == true and (c == '.' or c == ',') and (unicode.isNumber(nextv) or unicode.isLetter(nextv))) then
            is_letter = true
          end
        end
        if is_letter then
          if not(letter == true or space == true) or
             (letter == true and not is_mark and
              (prev_alphabet == 'placeholder' or
               (prev_alphabet == is_alphabet and inTable(is_alphabet, opt.segment_alphabet)) or
               (prev_alphabet ~= is_alphabet and opt.segment_alphabet_change))) then
            if opt.joiner_annotate and not(opt.joiner_new) then
              curtok = curtok .. opt.joiner
            end
            table.insert(tokens, curtok)
            if opt.joiner_annotate and opt.joiner_new then
              table.insert(tokens, opt.joiner)
            end
            curtok = ''
          elseif other == true then
            if opt.joiner_annotate then
              if curtok == '' then
                if opt.joiner_new then table.insert(tokens, opt.joiner)
                else tokens[#tokens] = tokens[#tokens] .. opt.joiner end
             end
           end
          end
          curtok = curtok .. c
          space = false
          number = false
          other = false
          letter = true
          prev_alphabet = is_alphabet
        elseif is_number then
          if letter == true or (number and opt.segment_numbers) or not(number == true or space == true) then
            local addjoiner = false
            if opt.joiner_annotate then
              if opt.joiner_new then
                addjoiner = true
              else
                if not(letter and prev_alphabet ~= 'placeholder') then
                  curtok = curtok .. opt.joiner
                else
                  c = opt.joiner .. c
                end
              end
            end
            table.insert(tokens, curtok)
            if addjoiner then
              table.insert(tokens, opt.joiner)
            end
            curtok = ''
          elseif other == true then
            if opt.joiner_annotate then
              if opt.joiner_new then
                table.insert(tokens, opt.joiner)
              else
                tokens[#tokens] = tokens[#tokens] .. opt.joiner
              end
            end
          end
          curtok = curtok..c
          space = false
          letter = false
          other = false
          number = true
        else
          if not space == true then
            if opt.joiner_annotate and not(opt.joiner_new) then
              c = opt.joiner .. c
            end
            table.insert(tokens, curtok)
            if opt.joiner_annotate and opt.joiner_new then
              table.insert(tokens, opt.joiner)
            end
            curtok = ''
          elseif other == true then
            if opt.joiner_annotate then
              if opt.joiner_new then
                table.insert(tokens, opt.joiner)
              else
                curtok = opt.joiner
              end
            end
          end
          curtok = curtok .. c
          table.insert(tokens, curtok)
          curtok = ''
          number = false
          letter = false
          other = true
          space = true
        end
      end
    end
  end

  -- last token
  if (curtok ~= '') then
    table.insert(tokens, curtok)
  end

  return tokens
end

function tokenizer.tokenize(opt, line, bpe)
  -- if tokenize hook, skip lua tokenization
  local tokens = _G.hookManager:call("tokenize", opt, line, bpe)

  -- otherwise internal tokenization
  if not tokens then

    -- tokenize
    tokens = tokenize(line, opt)

    -- apply segment feature if requested
    if opt.segment_case then
      local sep = ''
      if opt.joiner_annotate then sep = opt.joiner end
      tokens = case.segmentCase(tokens, sep)
    end

    -- apply bpe if requested
    if bpe then
      local sep = ''
      if opt.joiner_annotate then sep = opt.joiner end
      tokens = bpe:segment(tokens, sep)
    end

    -- add-up case feature if requested
    if opt.case_feature then
      tokens = case.addCase(tokens)
    end

  end

  -- post_tokenize hook for more features
  tokens = _G.hookManager:call("post_tokenize", opt, tokens) or tokens

  return tokens
end

local function extractJoiners(word, joiner)
  local leftJoin = false
  local rightJoin = false

  if word:sub(1, #joiner) == joiner then
    word = word:sub(1 + #joiner)
    leftJoin = true
    rightJoin = (word == '')
  end
  if word:sub(-#joiner, -1) == joiner then
    word = word:sub(1, -#joiner - 1)
    rightJoin = true
  end

  return word, leftJoin, rightJoin
end

function tokenizer.detokenize(opt, words, features)
  -- if tokenize hook, skip lua detokenization
  local line = _G.hookManager:call("detokenize", opt, words, features)
  if line then
    return line
  end

  line = ""
  local prevRightJoin = false

  for i = 1, #words do
    local token, leftJoin, rightJoin = extractJoiners(words[i], opt.joiner)
    local feats = {}
    if features then
      for j = 1, #features do
        table.insert(feats, features[j][i])
      end
    end

    if i > 1 and not prevRightJoin and not leftJoin then
      line = line .. " "
    end

    if token:sub(1, separators.ph_marker_open:len()) == separators.ph_marker_open then
      local inProtected = false
      local protectSeq = ''
      local rtok = ''
      for _, c, _ in unicode.utf8_iter(token) do
        if inProtected then
          protectSeq = protectSeq .. c
          if protectSeq:len() == 4 then
            rtok = rtok .. unicode._cp_to_utf8(tonumber(protectSeq, 16))
            inProtected = false
          end
        elseif c == separators.protected_character then
          inProtected = true
        else
          rtok = rtok .. c
          if c == separators.ph_marker_close then
            break
          end
        end
      end
      token = rtok
    end

    if opt.case_feature and #features > 0 then
      token = case.restoreCase(token, feats)
    end

    line = line .. token
    prevRightJoin = rightJoin
  end

  return line
end

function tokenizer.detokenizeLine(opt, line)
  -- TODO: use utility functions from onmt.utils.
  local words, features = {}, {}

  line:gsub("([^ ]+)", function(token)
    local p = token:find(separators.feat_marker)

    if p then
      table.insert(words, token:sub(1, p - 1))

      local feats = {}
      p = p + #separators.feat_marker
      local j = p
      while j <= #token do
        if token:sub(j, j+#separators.feat_marker-1) == separators.feat_marker then
          table.insert(feats, token:sub(p, j-1))
          j = j + #separators.feat_marker - 1
          p = j + 1
        end
        j = j + 1
      end
      table.insert(feats, token:sub(p))

      for f = 1, #feats do
        if f > #features then
          table.insert(features, {})
        end
        table.insert(features[f], feats[f])
      end
    else
      table.insert(words, token)
    end
  end)

  return tokenizer.detokenize(opt, words, features)
end

return tokenizer
