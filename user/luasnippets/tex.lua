local ls = require("luasnip")
local s = ls.snippet
local sn = ls.snippet_node
local isn = ls.indent_snippet_node
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node
local c = ls.choice_node
local d = ls.dynamic_node
local r = ls.restore_node
local events = require("luasnip.util.events")
local ai = require("luasnip.nodes.absolute_indexer")
local extras = require("luasnip.extras")
local l = extras.lambda
local rep = extras.rep
local p = extras.partial
local m = extras.match
local n = extras.nonempty
local dl = extras.dynamic_lambda
local fmt = require("luasnip.extras.fmt").fmt
local fmta = require("luasnip.extras.fmt").fmta
local conds = require("luasnip.extras.expand_conditions")
local postfix = require("luasnip.extras.postfix").postfix
local types = require("luasnip.util.types")
local parse = require("luasnip.util.parser").parse_snippet

-- local function copy(obj)
--     if type(obj) ~= 'table' then return obj end
--     local res = {}
--     for k, v in pairs(obj) do res[copy(k)] = copy(v) end
--     return res
-- end

local get_visual = function(_, parent)
    if (#parent.snippet.env.SELECT_RAW > 0) then
        return sn(nil, i(1, parent.snippet.env.SELECT_RAW))
    else
        return sn(nil, i(1))
    end
end

local line_begin = require("luasnip.extras.expand_conditions").line_begin

local multi_trigger_snippet = function(contexts, nodes, opts)
    local snippets = {}
    for _, context in pairs(contexts) do
        table.insert(snippets,
            vim.deepcopy(s(context, nodes, opts))
        )
    end
    return snippets
end

-- return a new array containing the concatenation of all of its
-- parameters. Scaler parameters are included in place, and array
-- parameters have their values shallow-copied to the final array.
-- Note that userdata and function values are treated as scalar.
local array_concat = function(...)
    local t = {}
    for n = 1, select("#", ...) do
        local arg = select(n, ...)
        if type(arg) == "table" then
            for _, v in ipairs(arg) do
                t[#t + 1] = v
            end
        else
            t[#t + 1] = arg
        end
    end
    return t
end

-- Some LaTeX-specific conditional expansion functions (requires VimTeX)

local tex_utils = {}
tex_utils.in_mathzone = function() -- math context detection
    return vim.fn['vimtex#syntax#in_mathzone']() == 1
end
tex_utils.in_text = function()
    return not tex_utils.in_mathzone()
end
tex_utils.in_comment = function() -- comment detection
    return vim.fn['vimtex#syntax#in_comment']() == 1
end
tex_utils.in_env = function(name) -- generic environment detection
    local is_inside = vim.fn['vimtex#env#is_inside'](name)
    return (is_inside[1] > 0 and is_inside[2] > 0)
end
-- A few concrete environments---adapt as needed
tex_utils.in_equation = function() -- equation environment detection
    return tex_utils.in_env('equation')
end
tex_utils.in_itemize = function() -- itemize environment detection
    return tex_utils.in_env('itemize')
end
tex_utils.in_tikz = function() -- TikZ picture environment detection
    return tex_utils.in_env('tikzpicture')
end

-- dynamic matrix
local mat = function(args, snip)
    local rows = tonumber(snip.captures[2])
    local cols = tonumber(snip.captures[3])
    local nodes = {}
    local ins_indx = 1
    for j = 1, rows do
        table.insert(nodes, r(ins_indx, tostring(j) .. "x1", i(1)))
        ins_indx = ins_indx + 1
        for k = 2, cols do
            table.insert(nodes, t " & ")
            table.insert(nodes, r(ins_indx, tostring(j) .. "x" .. tostring(k), i(1)))
            ins_indx = ins_indx + 1
        end
        if j ~= rows then
            if snip.captures[5] == "i" then
                table.insert(nodes, t { " \\\\ " })
            else
                table.insert(nodes, t { " \\\\", "" })
            end
        end
    end
    return sn(nil, nodes)
end

return array_concat(
-- mathmode on 'mm'
    multi_trigger_snippet(
        {
            { trig = "([^%w])mm", wordTrig = false, regTrig = true, snippetType = "autosnippet" },
            { trig = "^(a?)mm", wordTrig = false, regTrig = true, snippetType = "autosnippet" }
        },
        fmta(
            "<>$<>$",
            {
                f(function(_, snip) return snip.captures[1] end),
                d(1, get_visual),
            }
        ),
        { condition = tex_utils.in_text }
    ),
    -- displaymath on 'dmm'
    multi_trigger_snippet(
        {
            { trig = "([^%w])dmm", wordTrig = false, regTrig = true, snippetType = "autosnippet" },
            { trig = "^(a?)dmm", wordTrig = false, regTrig = true, snippetType = "autosnippet" },
        },
        fmta([[
            <>\[
                <>
            \]
            ]],
            {
                f(function(_, snip) return snip.captures[1] end),
                i(1),
            }
        ),
        { condition = tex_utils.in_text }

    ),
    -- fraction on 'ff'
    multi_trigger_snippet(
        {
            { trig = "([^%w])ff", wordTrig = false, regTrig = true, snippetType = "autosnippet" },
            { trig = "^(a?)ff", wordTrig = false, regTrig = true, snippetType = "autosnippet" }
        },
        fmta("<>\\frac{<>}{<>}",
            {
                f(function(_, snip) return snip.captures[1] end),
                d(1, get_visual),
                i(2)
            }
        ),
        { condition = tex_utils.in_mathzone }
    ),

    {
        -- begin environment
        s({ trig = "env", snippetType = "autosnippet" },
            fmta(
                [[
                \begin{<>}
                    <>
                \end{<>}
            ]]   ,
                {
                    i(1),
                    i(2),
                    rep(1),
                }
            ),
            { condition = line_begin }
        ),
        -- matrix
        s({ trig = '([bBpvV])mat(%d+)x(%d+)([a]?)([i]?)', regTrig = true, name = 'matrix',
            dscr = 'matrix trigger lets go' }
            ,
            fmta([[
                \begin{<>}<>
                <>
                \end{<>}]],
                { f(function(_, snip) return snip.captures[1] .. "matrix" end),
                    f(function(_, snip) -- augments
                        if snip.captures[4] == "a" then
                            local out = string.rep("c", tonumber(snip.captures[3]) - 1)
                            return "[" .. out .. "|c]"
                        end
                        return ""
                    end),
                    d(1, mat),
                    f(function(_, snip) return snip.captures[1] .. "matrix" end) }
            )
        )
    }
)
