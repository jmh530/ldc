/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (c) 1999-2017 by Digital Mars, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/ddmd/lexer.d, _lexer.d)
 */

module ddmd.lexer;

// Online documentation: https://dlang.org/phobos/ddmd_lexer.html

import core.stdc.ctype;
import core.stdc.errno;
import core.stdc.stdarg;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.time;

import ddmd.entity;
import ddmd.errors;
import ddmd.globals;
import ddmd.id;
import ddmd.identifier;
import ddmd.root.ctfloat;
import ddmd.root.outbuffer;
import ddmd.root.port;
import ddmd.root.rmem;
import ddmd.tokens;
import ddmd.utf;

enum LS = 0x2028;       // UTF line separator
enum PS = 0x2029;       // UTF paragraph separator

/********************************************
 * Do our own char maps
 */
immutable ubyte[256] cmtable;
enum CMoctal  = 0x1;
enum CMhex    = 0x2;
enum CMidchar = 0x4;
enum CMzerosecond = 0x8;
enum CMdigitsecond = 0x10;
enum CMsinglechar = 0x20;

bool isoctal(char c)
{
    return (cmtable[c] & CMoctal) != 0;
}

bool ishex(char c)
{
    return (cmtable[c] & CMhex) != 0;
}

bool isidchar(char c)
{
    return (cmtable[c] & CMidchar) != 0;
}

bool isZeroSecond(char c)
{
    return (cmtable[c] & CMzerosecond) != 0;
}

bool isDigitSecond(char c)
{
    return (cmtable[c] & CMdigitsecond) != 0;
}

bool issinglechar(char c)
{
    return (cmtable[c] & CMsinglechar) != 0;
}

static this()
{
    foreach (const c; 0 .. cmtable.length)
    {
        if ('0' <= c && c <= '7')
            cmtable[c] |= CMoctal;
        if (isxdigit(c))
            cmtable[c] |= CMhex;
        if (isalnum(c) || c == '_')
            cmtable[c] |= CMidchar;

        switch (c)
        {
            case 'x': case 'X':
            case 'b': case 'B':
                cmtable[c] |= CMzerosecond;
                break;

            case '0': .. case '9':
            case 'e': case 'E':
            case 'f': case 'F':
            case 'l': case 'L':
            case 'p': case 'P':
            case 'u': case 'U':
            case 'i':
            case '.':
            case '_':
                cmtable[c] |= CMzerosecond | CMdigitsecond;
                break;

            default:
                break;
        }

        switch (c)
        {
            case '\\':
            case '\n':
            case '\r':
            case 0:
            case 0x1A:
            case '\'':
                break;
            default:
                if (!(c & 0x80))
                    cmtable[c] |= CMsinglechar;
                break;
        }
    }
}

unittest
{
    //printf("lexer.unittest\n");
    /* Not much here, just trying things out.
     */
    string text = "int"; // We rely on the implicit null-terminator
    scope Lexer lex1 = new Lexer(null, text.ptr, 0, text.length, 0, 0);
    TOK tok;
    tok = lex1.nextToken();
    //printf("tok == %s, %d, %d\n", Token::toChars(tok), tok, TOKint32);
    assert(tok == TOKint32);
    tok = lex1.nextToken();
    assert(tok == TOKeof);
    tok = lex1.nextToken();
    assert(tok == TOKeof);
    tok = lex1.nextToken();
    assert(tok == TOKeof);
}

unittest
{
    // We don't want to see Lexer error output during these tests.
    uint errors = global.startGagging();
    scope(exit) global.endGagging(errors);

    // Test malformed input: even malformed input should end in a TOKeof.
    static immutable char[][] testcases =
    [   // Testcase must end with 0 or 0x1A.
        [0], // not malformed, but pathological
        ['\'', 0],
        ['\'', 0x1A],
        ['{', '{', 'q', '{', 0],
        [0xFF, 0],
        [0xFF, 0x80, 0],
        [0xFF, 0xFF, 0],
        [0xFF, 0xFF, 0],
        ['x', '"', 0x1A],
    ];

    foreach (testcase; testcases)
    {
        scope Lexer lex2 = new Lexer(null, testcase.ptr, 0, testcase.length-1, 0, 0);
        TOK tok = lex2.nextToken();
        size_t iterations = 1;
        while ((tok != TOKeof) && (iterations++ < testcase.length))
        {
            tok = lex2.nextToken();
        }
        assert(tok == TOKeof);
        tok = lex2.nextToken();
        assert(tok == TOKeof);
    }
}

/***********************************************************
 */
class Lexer
{
    __gshared OutBuffer stringbuffer;

    Loc scanloc;            // for error messages
    Loc prevloc;            // location of token before current

    const(char)* base;      // pointer to start of buffer
    const(char)* end;       // pointer to last element of buffer
    const(char)* p;         // current character
    const(char)* line;      // start of current line
    Token token;
    bool doDocComment;      // collect doc comment information
    bool anyToken;          // seen at least one token
    bool commentToken;      // comments are TOKcomment's
    int lastDocLine;        // last line of previous doc comment
    bool errors;            // errors occurred during lexing or parsing

    /*********************
     * Creates a Lexer for the source code base[begoffset..endoffset+1].
     * The last character, base[endoffset], must be null (0) or EOF (0x1A).
     *
     * Params:
     *  filename = used for error messages
     *  base = source code, must be terminated by a null (0) or EOF (0x1A) character
     *  begoffset = starting offset into base[]
     *  endoffset = the last offset to read into base[]
     *  doDocComment = handle documentation comments
     *  commentToken = comments become TOKcomment's
     */
    this(const(char)* filename, const(char)* base, size_t begoffset, size_t endoffset, bool doDocComment, bool commentToken)
    {
        scanloc = Loc(filename, 1, 1);
        //printf("Lexer::Lexer(%p,%d)\n",base,length);
        //printf("lexer.filename = %s\n", filename);
        token = Token.init;
        this.base = base;
        this.end = base + endoffset;
        p = base + begoffset;
        line = p;
        this.doDocComment = doDocComment;
        this.commentToken = commentToken;
        this.lastDocLine = 0;
        //initKeywords();
        /* If first line starts with '#!', ignore the line
         */
        if (p && p[0] == '#' && p[1] == '!')
        {
            p += 2;
            while (1)
            {
                char c = *p++;
                switch (c)
                {
                case 0:
                case 0x1A:
                    p--;
                    goto case;
                case '\n':
                    break;
                default:
                    continue;
                }
                break;
            }
            endOfLine();
        }
    }

    final TOK nextToken()
    {
        prevloc = token.loc;
        if (token.next)
        {
            Token* t = token.next;
            memcpy(&token, t, Token.sizeof);
            t.free();
        }
        else
        {
            scan(&token);
        }
        //token.print();
        return token.value;
    }

    /***********************
     * Look ahead at next token's value.
     */
    final TOK peekNext()
    {
        return peek(&token).value;
    }

    /***********************
     * Look 2 tokens ahead at value.
     */
    final TOK peekNext2()
    {
        Token* t = peek(&token);
        return peek(t).value;
    }

    /****************************
     * Turn next token in buffer into a token.
     */
    final void scan(Token* t)
    {
        const lastLine = scanloc.linnum;
        Loc startLoc;
        t.blockComment = null;
        t.lineComment = null;

        while (1)
        {
            t.ptr = p;
            //printf("p = %p, *p = '%c'\n",p,*p);
            t.loc = loc();
            switch (*p)
            {
            case 0:
            case 0x1A:
                t.value = TOKeof; // end of file
                // Intentionally not advancing `p`, such that subsequent calls keep returning TOKeof.
                return;
            case ' ':
            case '\t':
            case '\v':
            case '\f':
                p++;
                continue; // skip white space
            case '\r':
                p++;
                if (*p != '\n') // if CR stands by itself
                    endOfLine();
                continue; // skip white space
            case '\n':
                p++;
                endOfLine();
                continue; // skip white space
            case '0':
                if (!isZeroSecond(p[1]))        // if numeric literal does not continue
                {
                    ++p;
                    t.uns64value = 0;
                    t.value = TOKint32v;
                    return;
                }
                goto Lnumber;

            case '1': .. case '9':
                if (!isDigitSecond(p[1]))       // if numeric literal does not continue
                {
                    t.uns64value = *p - '0';
                    ++p;
                    t.value = TOKint32v;
                    return;
                }
            Lnumber:
                t.value = number(t);
                return;

            case '\'':
                if (issinglechar(p[1]) && p[2] == '\'')
                {
                    t.uns64value = p[1];        // simple one character literal
                    t.value = TOKcharv;
                    p += 3;
                }
                else
                    t.value = charConstant(t);
                return;
            case 'r':
                if (p[1] != '"')
                    goto case_ident;
                p++;
                goto case '`';
            case '`':
                t.value = wysiwygStringConstant(t, *p);
                return;
            case 'x':
                if (p[1] != '"')
                    goto case_ident;
                p++;
                t.value = hexStringConstant(t);
                return;
            case 'q':
                if (p[1] == '"')
                {
                    p++;
                    t.value = delimitedStringConstant(t);
                    return;
                }
                else if (p[1] == '{')
                {
                    p++;
                    t.value = tokenStringConstant(t);
                    return;
                }
                else
                    goto case_ident;
            case '"':
                t.value = escapeStringConstant(t, 0);
                return;
            case 'a':
            case 'b':
            case 'c':
            case 'd':
            case 'e':
            case 'f':
            case 'g':
            case 'h':
            case 'i':
            case 'j':
            case 'k':
            case 'l':
            case 'm':
            case 'n':
            case 'o':
            case 'p':
                /*case 'q': case 'r':*/
            case 's':
            case 't':
            case 'u':
            case 'v':
            case 'w':
                /*case 'x':*/
            case 'y':
            case 'z':
            case 'A':
            case 'B':
            case 'C':
            case 'D':
            case 'E':
            case 'F':
            case 'G':
            case 'H':
            case 'I':
            case 'J':
            case 'K':
            case 'L':
            case 'M':
            case 'N':
            case 'O':
            case 'P':
            case 'Q':
            case 'R':
            case 'S':
            case 'T':
            case 'U':
            case 'V':
            case 'W':
            case 'X':
            case 'Y':
            case 'Z':
            case '_':
            case_ident:
                {
                    while (1)
                    {
                        const c = *++p;
                        if (isidchar(c))
                            continue;
                        else if (c & 0x80)
                        {
                            const s = p;
                            const u = decodeUTF();
                            if (isUniAlpha(u))
                                continue;
                            error("char 0x%04x not allowed in identifier", u);
                            p = s;
                        }
                        break;
                    }
                    Identifier id = Identifier.idPool(cast(char*)t.ptr, p - t.ptr);
                    t.ident = id;
                    t.value = cast(TOK)id.getValue();
                    anyToken = 1;
                    if (*t.ptr == '_') // if special identifier token
                    {
                        __gshared bool initdone = false;
                        __gshared char[11 + 1] date;
                        __gshared char[8 + 1] time;
                        __gshared char[24 + 1] timestamp;
                        if (!initdone) // lazy evaluation
                        {
                            initdone = true;
                            time_t ct;
                            .time(&ct);
                            const p = ctime(&ct);
                            assert(p);
                            sprintf(&date[0], "%.6s %.4s", p + 4, p + 20);
                            sprintf(&time[0], "%.8s", p + 11);
                            sprintf(&timestamp[0], "%.24s", p);
                        }
                        if (id == Id.DATE)
                        {
                            t.ustring = date.ptr;
                            goto Lstr;
                        }
                        else if (id == Id.TIME)
                        {
                            t.ustring = time.ptr;
                            goto Lstr;
                        }
                        else if (id == Id.VENDOR)
                        {
                            t.ustring = global.compiler.vendor;
                            goto Lstr;
                        }
                        else if (id == Id.TIMESTAMP)
                        {
                            t.ustring = timestamp.ptr;
                        Lstr:
                            t.value = TOKstring;
                            t.postfix = 0;
                            t.len = cast(uint)strlen(t.ustring);
                        }
                        else if (id == Id.VERSIONX)
                        {
                            uint major = 0;
                            uint minor = 0;
                            bool point = false;
                            for (const(char)* p = global._version + 1; 1; p++)
                            {
                                const c = *p;
                                if (isdigit(cast(char)c))
                                    minor = minor * 10 + c - '0';
                                else if (c == '.')
                                {
                                    if (point)
                                        break; // ignore everything after second '.'
                                    point = true;
                                    major = minor;
                                    minor = 0;
                                }
                                else
                                    break;
                            }
                            t.value = TOKint64v;
                            t.uns64value = major * 1000 + minor;
                        }
                        else if (id == Id.EOFX)
                        {
                            t.value = TOKeof;
                            // Advance scanner to end of file
                            while (!(*p == 0 || *p == 0x1A))
                                p++;
                        }
                    }
                    //printf("t.value = %d\n",t.value);
                    return;
                }
            case '/':
                p++;
                switch (*p)
                {
                case '=':
                    p++;
                    t.value = TOKdivass;
                    return;
                case '*':
                    p++;
                    startLoc = loc();
                    while (1)
                    {
                        while (1)
                        {
                            const c = *p;
                            switch (c)
                            {
                            case '/':
                                break;
                            case '\n':
                                endOfLine();
                                p++;
                                continue;
                            case '\r':
                                p++;
                                if (*p != '\n')
                                    endOfLine();
                                continue;
                            case 0:
                            case 0x1A:
                                error("unterminated /* */ comment");
                                p = end;
                                t.loc = loc();
                                t.value = TOKeof;
                                return;
                            default:
                                if (c & 0x80)
                                {
                                    const u = decodeUTF();
                                    if (u == PS || u == LS)
                                        endOfLine();
                                }
                                p++;
                                continue;
                            }
                            break;
                        }
                        p++;
                        if (p[-2] == '*' && p - 3 != t.ptr)
                            break;
                    }
                    if (commentToken)
                    {
                        t.loc = startLoc;
                        t.value = TOKcomment;
                        return;
                    }
                    else if (doDocComment && t.ptr[2] == '*' && p - 4 != t.ptr)
                    {
                        // if /** but not /**/
                        getDocComment(t, lastLine == startLoc.linnum, startLoc.linnum - lastDocLine > 1);
                        lastDocLine = scanloc.linnum;
                    }
                    continue;
                case '/': // do // style comments
                    startLoc = loc();
                    while (1)
                    {
                        const c = *++p;
                        switch (c)
                        {
                        case '\n':
                            break;
                        case '\r':
                            if (p[1] == '\n')
                                p++;
                            break;
                        case 0:
                        case 0x1A:
                            if (commentToken)
                            {
                                p = end;
                                t.loc = startLoc;
                                t.value = TOKcomment;
                                return;
                            }
                            if (doDocComment && t.ptr[2] == '/')
                            {
                                getDocComment(t, lastLine == startLoc.linnum, startLoc.linnum - lastDocLine > 1);
                                lastDocLine = scanloc.linnum;
                            }
                            p = end;
                            t.loc = loc();
                            t.value = TOKeof;
                            return;
                        default:
                            if (c & 0x80)
                            {
                                const u = decodeUTF();
                                if (u == PS || u == LS)
                                    break;
                            }
                            continue;
                        }
                        break;
                    }
                    if (commentToken)
                    {
                        p++;
                        endOfLine();
                        t.loc = startLoc;
                        t.value = TOKcomment;
                        return;
                    }
                    if (doDocComment && t.ptr[2] == '/')
                    {
                        getDocComment(t, lastLine == startLoc.linnum, startLoc.linnum - lastDocLine > 1);
                        lastDocLine = scanloc.linnum;
                    }
                    p++;
                    endOfLine();
                    continue;
                case '+':
                    {
                        int nest;
                        startLoc = loc();
                        p++;
                        nest = 1;
                        while (1)
                        {
                            char c = *p;
                            switch (c)
                            {
                            case '/':
                                p++;
                                if (*p == '+')
                                {
                                    p++;
                                    nest++;
                                }
                                continue;
                            case '+':
                                p++;
                                if (*p == '/')
                                {
                                    p++;
                                    if (--nest == 0)
                                        break;
                                }
                                continue;
                            case '\r':
                                p++;
                                if (*p != '\n')
                                    endOfLine();
                                continue;
                            case '\n':
                                endOfLine();
                                p++;
                                continue;
                            case 0:
                            case 0x1A:
                                error("unterminated /+ +/ comment");
                                p = end;
                                t.loc = loc();
                                t.value = TOKeof;
                                return;
                            default:
                                if (c & 0x80)
                                {
                                    uint u = decodeUTF();
                                    if (u == PS || u == LS)
                                        endOfLine();
                                }
                                p++;
                                continue;
                            }
                            break;
                        }
                        if (commentToken)
                        {
                            t.loc = startLoc;
                            t.value = TOKcomment;
                            return;
                        }
                        if (doDocComment && t.ptr[2] == '+' && p - 4 != t.ptr)
                        {
                            // if /++ but not /++/
                            getDocComment(t, lastLine == startLoc.linnum, startLoc.linnum - lastDocLine > 1);
                            lastDocLine = scanloc.linnum;
                        }
                        continue;
                    }
                default:
                    break;
                }
                t.value = TOKdiv;
                return;
            case '.':
                p++;
                if (isdigit(*p))
                {
                    /* Note that we don't allow ._1 and ._ as being
                     * valid floating point numbers.
                     */
                    p--;
                    t.value = inreal(t);
                }
                else if (p[0] == '.')
                {
                    if (p[1] == '.')
                    {
                        p += 2;
                        t.value = TOKdotdotdot;
                    }
                    else
                    {
                        p++;
                        t.value = TOKslice;
                    }
                }
                else
                    t.value = TOKdot;
                return;
            case '&':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKandass;
                }
                else if (*p == '&')
                {
                    p++;
                    t.value = TOKandand;
                }
                else
                    t.value = TOKand;
                return;
            case '|':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKorass;
                }
                else if (*p == '|')
                {
                    p++;
                    t.value = TOKoror;
                }
                else
                    t.value = TOKor;
                return;
            case '-':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKminass;
                }
                else if (*p == '-')
                {
                    p++;
                    t.value = TOKminusminus;
                }
                else
                    t.value = TOKmin;
                return;
            case '+':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKaddass;
                }
                else if (*p == '+')
                {
                    p++;
                    t.value = TOKplusplus;
                }
                else
                    t.value = TOKadd;
                return;
            case '<':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKle; // <=
                }
                else if (*p == '<')
                {
                    p++;
                    if (*p == '=')
                    {
                        p++;
                        t.value = TOKshlass; // <<=
                    }
                    else
                        t.value = TOKshl; // <<
                }
                else if (*p == '>')
                {
                    p++;
                    if (*p == '=')
                    {
                        p++;
                        t.value = TOKleg; // <>=
                    }
                    else
                        t.value = TOKlg; // <>
                }
                else
                    t.value = TOKlt; // <
                return;
            case '>':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKge; // >=
                }
                else if (*p == '>')
                {
                    p++;
                    if (*p == '=')
                    {
                        p++;
                        t.value = TOKshrass; // >>=
                    }
                    else if (*p == '>')
                    {
                        p++;
                        if (*p == '=')
                        {
                            p++;
                            t.value = TOKushrass; // >>>=
                        }
                        else
                            t.value = TOKushr; // >>>
                    }
                    else
                        t.value = TOKshr; // >>
                }
                else
                    t.value = TOKgt; // >
                return;
            case '!':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKnotequal; // !=
                }
                else if (*p == '<')
                {
                    p++;
                    if (*p == '>')
                    {
                        p++;
                        if (*p == '=')
                        {
                            p++;
                            t.value = TOKunord; // !<>=
                        }
                        else
                            t.value = TOKue; // !<>
                    }
                    else if (*p == '=')
                    {
                        p++;
                        t.value = TOKug; // !<=
                    }
                    else
                        t.value = TOKuge; // !<
                }
                else if (*p == '>')
                {
                    p++;
                    if (*p == '=')
                    {
                        p++;
                        t.value = TOKul; // !>=
                    }
                    else
                        t.value = TOKule; // !>
                }
                else
                    t.value = TOKnot; // !
                return;
            case '=':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKequal; // ==
                }
                else if (*p == '>')
                {
                    p++;
                    t.value = TOKgoesto; // =>
                }
                else
                    t.value = TOKassign; // =
                return;
            case '~':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKcatass; // ~=
                }
                else
                    t.value = TOKtilde; // ~
                return;
            case '^':
                p++;
                if (*p == '^')
                {
                    p++;
                    if (*p == '=')
                    {
                        p++;
                        t.value = TOKpowass; // ^^=
                    }
                    else
                        t.value = TOKpow; // ^^
                }
                else if (*p == '=')
                {
                    p++;
                    t.value = TOKxorass; // ^=
                }
                else
                    t.value = TOKxor; // ^
                return;
            case '(':
                p++;
                t.value = TOKlparen;
                return;
            case ')':
                p++;
                t.value = TOKrparen;
                return;
            case '[':
                p++;
                t.value = TOKlbracket;
                return;
            case ']':
                p++;
                t.value = TOKrbracket;
                return;
            case '{':
                p++;
                t.value = TOKlcurly;
                return;
            case '}':
                p++;
                t.value = TOKrcurly;
                return;
            case '?':
                p++;
                t.value = TOKquestion;
                return;
            case ',':
                p++;
                t.value = TOKcomma;
                return;
            case ';':
                p++;
                t.value = TOKsemicolon;
                return;
            case ':':
                p++;
                t.value = TOKcolon;
                return;
            case '$':
                p++;
                t.value = TOKdollar;
                return;
            case '@':
                p++;
                t.value = TOKat;
                return;
            case '*':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKmulass;
                }
                else
                    t.value = TOKmul;
                return;
            case '%':
                p++;
                if (*p == '=')
                {
                    p++;
                    t.value = TOKmodass;
                }
                else
                    t.value = TOKmod;
                return;
            case '#':
                {
                    p++;
                    Token n;
                    scan(&n);
                    if (n.value == TOKidentifier && n.ident == Id.line)
                    {
                        poundLine();
                        continue;
                    }
                    else
                    {
                        t.value = TOKpound;
                        return;
                    }
                }
            default:
                {
                    dchar c = *p;
                    if (c & 0x80)
                    {
                        c = decodeUTF();
                        // Check for start of unicode identifier
                        if (isUniAlpha(c))
                            goto case_ident;
                        if (c == PS || c == LS)
                        {
                            endOfLine();
                            p++;
                            continue;
                        }
                    }
                    if (c < 0x80 && isprint(c))
                        error("character '%c' is not a valid token", c);
                    else
                        error("character 0x%02x is not a valid token", c);
                    p++;
                    continue;
                }
            }
        }
    }

    final Token* peek(Token* ct)
    {
        Token* t;
        if (ct.next)
            t = ct.next;
        else
        {
            t = Token.alloc();
            scan(t);
            ct.next = t;
        }
        return t;
    }

    /*********************************
     * tk is on the opening (.
     * Look ahead and return token that is past the closing ).
     */
    final Token* peekPastParen(Token* tk)
    {
        //printf("peekPastParen()\n");
        int parens = 1;
        int curlynest = 0;
        while (1)
        {
            tk = peek(tk);
            //tk.print();
            switch (tk.value)
            {
            case TOKlparen:
                parens++;
                continue;
            case TOKrparen:
                --parens;
                if (parens)
                    continue;
                tk = peek(tk);
                break;
            case TOKlcurly:
                curlynest++;
                continue;
            case TOKrcurly:
                if (--curlynest >= 0)
                    continue;
                break;
            case TOKsemicolon:
                if (curlynest)
                    continue;
                break;
            case TOKeof:
                break;
            default:
                continue;
            }
            return tk;
        }
    }

    /*******************************************
     * Parse escape sequence.
     */
    final uint escapeSequence()
    {
        uint c = *p;
        int ndigits;
        switch (c)
        {
        case '\'':
        case '"':
        case '?':
        case '\\':
        Lconsume:
            p++;
            break;
        case 'a':
            c = 7;
            goto Lconsume;
        case 'b':
            c = 8;
            goto Lconsume;
        case 'f':
            c = 12;
            goto Lconsume;
        case 'n':
            c = 10;
            goto Lconsume;
        case 'r':
            c = 13;
            goto Lconsume;
        case 't':
            c = 9;
            goto Lconsume;
        case 'v':
            c = 11;
            goto Lconsume;
        case 'u':
            ndigits = 4;
            goto Lhex;
        case 'U':
            ndigits = 8;
            goto Lhex;
        case 'x':
            ndigits = 2;
        Lhex:
            p++;
            c = *p;
            if (ishex(cast(char)c))
            {
                uint v = 0;
                int n = 0;
                while (1)
                {
                    if (isdigit(cast(char)c))
                        c -= '0';
                    else if (islower(c))
                        c -= 'a' - 10;
                    else
                        c -= 'A' - 10;
                    v = v * 16 + c;
                    c = *++p;
                    if (++n == ndigits)
                        break;
                    if (!ishex(cast(char)c))
                    {
                        error("escape hex sequence has %d hex digits instead of %d", n, ndigits);
                        break;
                    }
                }
                if (ndigits != 2 && !utf_isValidDchar(v))
                {
                    error("invalid UTF character \\U%08x", v);
                    v = '?'; // recover with valid UTF character
                }
                c = v;
            }
            else
                error("undefined escape hex sequence \\%c", c);
            break;
        case '&':
            // named character entity
            for (const idstart = ++p; 1; p++)
            {
                switch (*p)
                {
                case ';':
                    c = HtmlNamedEntity(idstart, p - idstart);
                    if (c == ~0)
                    {
                        error("unnamed character entity &%.*s;", cast(int)(p - idstart), idstart);
                        c = ' ';
                    }
                    p++;
                    break;
                default:
                    if (isalpha(*p) || (p != idstart && isdigit(*p)))
                        continue;
                    error("unterminated named entity &%.*s;", cast(int)(p - idstart + 1), idstart);
                    break;
                }
                break;
            }
            break;
        case 0:
        case 0x1A:
            // end of file
            c = '\\';
            break;
        default:
            if (isoctal(cast(char)c))
            {
                uint v = 0;
                int n = 0;
                do
                {
                    v = v * 8 + (c - '0');
                    c = *++p;
                }
                while (++n < 3 && isoctal(cast(char)c));
                c = v;
                if (c > 0xFF)
                    error("escape octal sequence \\%03o is larger than \\377", c);
            }
            else
                error("undefined escape sequence \\%c", c);
            break;
        }
        return c;
    }

    /**************************************
     */
    final TOK wysiwygStringConstant(Token* t, int tc)
    {
        Loc start = loc();
        p++;
        stringbuffer.reset();
        while (1)
        {
            dchar c = *p++;
            switch (c)
            {
            case '\n':
                endOfLine();
                break;
            case '\r':
                if (*p == '\n')
                    continue; // ignore
                c = '\n'; // treat EndOfLine as \n character
                endOfLine();
                break;
            case 0:
            case 0x1A:
                error("unterminated string constant starting at %s", start.toChars());
                t.setString();
                // decrement `p`, because it needs to point to the next token (the 0 or 0x1A character is the TOKeof token).
                p--;
                return TOKstring;
            case '"':
            case '`':
                if (c == tc)
                {
                    t.setString(stringbuffer);
                    stringPostfix(t);
                    return TOKstring;
                }
                break;
            default:
                if (c & 0x80)
                {
                    p--;
                    const u = decodeUTF();
                    p++;
                    if (u == PS || u == LS)
                        endOfLine();
                    stringbuffer.writeUTF8(u);
                    continue;
                }
                break;
            }
            stringbuffer.writeByte(c);
        }
    }

    /**************************************
     * Lex hex strings:
     *      x"0A ae 34FE BD"
     */
    final TOK hexStringConstant(Token* t)
    {
        Loc start = loc();
        uint n = 0;
        uint v = ~0; // dead assignment, needed to suppress warning
        p++;
        stringbuffer.reset();
        while (1)
        {
            dchar c = *p++;
            switch (c)
            {
            case ' ':
            case '\t':
            case '\v':
            case '\f':
                continue; // skip white space
            case '\r':
                if (*p == '\n')
                    continue; // ignore '\r' if followed by '\n'
                // Treat isolated '\r' as if it were a '\n'
                goto case '\n';
            case '\n':
                endOfLine();
                continue;
            case 0:
            case 0x1A:
                error("unterminated string constant starting at %s", start.toChars());
                t.setString();
                // decrement `p`, because it needs to point to the next token (the 0 or 0x1A character is the TOKeof token).
                p--;
                return TOKxstring;
            case '"':
                if (n & 1)
                {
                    error("odd number (%d) of hex characters in hex string", n);
                    stringbuffer.writeByte(v);
                }
                t.setString(stringbuffer);
                stringPostfix(t);
                return TOKxstring;
            default:
                if (c >= '0' && c <= '9')
                    c -= '0';
                else if (c >= 'a' && c <= 'f')
                    c -= 'a' - 10;
                else if (c >= 'A' && c <= 'F')
                    c -= 'A' - 10;
                else if (c & 0x80)
                {
                    p--;
                    const u = decodeUTF();
                    p++;
                    if (u == PS || u == LS)
                        endOfLine();
                    else
                        error("non-hex character \\u%04x in hex string", u);
                }
                else
                    error("non-hex character '%c' in hex string", c);
                if (n & 1)
                {
                    v = (v << 4) | c;
                    stringbuffer.writeByte(v);
                }
                else
                    v = c;
                n++;
                break;
            }
        }
        assert(0); // see bug 15731
    }

    /**************************************
     * Lex delimited strings:
     *      q"(foo(xxx))"   // "foo(xxx)"
     *      q"[foo$(LPAREN)]"       // "foo$(LPAREN)"
     *      q"/foo]/"       // "foo]"
     *      q"HERE
     *      foo
     *      HERE"           // "foo\n"
     * Input:
     *      p is on the "
     */
    final TOK delimitedStringConstant(Token* t)
    {
        Loc start = loc();
        dchar delimleft = 0;
        dchar delimright = 0;
        uint nest = 1;
        uint nestcount = ~0; // dead assignment, needed to suppress warning
        Identifier hereid = null;
        uint blankrol = 0;
        uint startline = 0;
        p++;
        stringbuffer.reset();
        while (1)
        {
            dchar c = *p++;
            //printf("c = '%c'\n", c);
            switch (c)
            {
            case '\n':
            Lnextline:
                endOfLine();
                startline = 1;
                if (blankrol)
                {
                    blankrol = 0;
                    continue;
                }
                if (hereid)
                {
                    stringbuffer.writeUTF8(c);
                    continue;
                }
                break;
            case '\r':
                if (*p == '\n')
                    continue; // ignore
                c = '\n'; // treat EndOfLine as \n character
                goto Lnextline;
            case 0:
            case 0x1A:
                error("unterminated delimited string constant starting at %s", start.toChars());
                t.setString();
                // decrement `p`, because it needs to point to the next token (the 0 or 0x1A character is the TOKeof token).
                p--;
                return TOKstring;
            default:
                if (c & 0x80)
                {
                    p--;
                    c = decodeUTF();
                    p++;
                    if (c == PS || c == LS)
                        goto Lnextline;
                }
                break;
            }
            if (delimleft == 0)
            {
                delimleft = c;
                nest = 1;
                nestcount = 1;
                if (c == '(')
                    delimright = ')';
                else if (c == '{')
                    delimright = '}';
                else if (c == '[')
                    delimright = ']';
                else if (c == '<')
                    delimright = '>';
                else if (isalpha(c) || c == '_' || (c >= 0x80 && isUniAlpha(c)))
                {
                    // Start of identifier; must be a heredoc
                    Token tok;
                    p--;
                    scan(&tok); // read in heredoc identifier
                    if (tok.value != TOKidentifier)
                    {
                        error("identifier expected for heredoc, not %s", tok.toChars());
                        delimright = c;
                    }
                    else
                    {
                        hereid = tok.ident;
                        //printf("hereid = '%s'\n", hereid.toChars());
                        blankrol = 1;
                    }
                    nest = 0;
                }
                else
                {
                    delimright = c;
                    nest = 0;
                    if (isspace(c))
                        error("delimiter cannot be whitespace");
                }
            }
            else
            {
                if (blankrol)
                {
                    error("heredoc rest of line should be blank");
                    blankrol = 0;
                    continue;
                }
                if (nest == 1)
                {
                    if (c == delimleft)
                        nestcount++;
                    else if (c == delimright)
                    {
                        nestcount--;
                        if (nestcount == 0)
                            goto Ldone;
                    }
                }
                else if (c == delimright)
                    goto Ldone;
                if (startline && isalpha(c) && hereid)
                {
                    Token tok;
                    auto psave = p;
                    p--;
                    scan(&tok); // read in possible heredoc identifier
                    //printf("endid = '%s'\n", tok.ident.toChars());
                    if (tok.value == TOKidentifier && tok.ident.equals(hereid))
                    {
                        /* should check that rest of line is blank
                         */
                        goto Ldone;
                    }
                    p = psave;
                }
                stringbuffer.writeUTF8(c);
                startline = 0;
            }
        }
    Ldone:
        if (*p == '"')
            p++;
        else if (hereid)
            error("delimited string must end in %s\"", hereid.toChars());
        else
            error("delimited string must end in %c\"", delimright);
        t.setString(stringbuffer);
        stringPostfix(t);
        return TOKstring;
    }

    /**************************************
     * Lex delimited strings:
     *      q{ foo(xxx) } // " foo(xxx) "
     *      q{foo$(LPAREN)}       // "foo$(LPAREN)"
     *      q{{foo}"}"}   // "{foo}"}""
     * Input:
     *      p is on the q
     */
    final TOK tokenStringConstant(Token* t)
    {
        uint nest = 1;
        const start = loc();
        const pstart = ++p;
        while (1)
        {
            Token tok;
            scan(&tok);
            switch (tok.value)
            {
            case TOKlcurly:
                nest++;
                continue;
            case TOKrcurly:
                if (--nest == 0)
                {
                    t.setString(pstart, p - 1 - pstart);
                    stringPostfix(t);
                    return TOKstring;
                }
                continue;
            case TOKeof:
                error("unterminated token string constant starting at %s", start.toChars());
                t.setString();
                return TOKstring;
            default:
                continue;
            }
        }
    }

    /**************************************
     */
    final TOK escapeStringConstant(Token* t, int wide)
    {
        const start = loc();
        p++;
        stringbuffer.reset();
        while (1)
        {
            dchar c = *p++;
            switch (c)
            {
            case '\\':
                switch (*p)
                {
                case 'u':
                case 'U':
                case '&':
                    c = escapeSequence();
                    stringbuffer.writeUTF8(c);
                    continue;
                default:
                    c = escapeSequence();
                    break;
                }
                break;
            case '\n':
                endOfLine();
                break;
            case '\r':
                if (*p == '\n')
                    continue; // ignore
                c = '\n'; // treat EndOfLine as \n character
                endOfLine();
                break;
            case '"':
                t.setString(stringbuffer);
                stringPostfix(t);
                return TOKstring;
            case 0:
            case 0x1A:
                // decrement `p`, because it needs to point to the next token (the 0 or 0x1A character is the TOKeof token).
                p--;
                error("unterminated string constant starting at %s", start.toChars());
                t.setString();
                return TOKstring;
            default:
                if (c & 0x80)
                {
                    p--;
                    c = decodeUTF();
                    if (c == LS || c == PS)
                    {
                        c = '\n';
                        endOfLine();
                    }
                    p++;
                    stringbuffer.writeUTF8(c);
                    continue;
                }
                break;
            }
            stringbuffer.writeByte(c);
        }
    }

    /**************************************
     */
    final TOK charConstant(Token* t)
    {
        TOK tk = TOKcharv;
        //printf("Lexer::charConstant\n");
        p++;
        dchar c = *p++;
        switch (c)
        {
        case '\\':
            switch (*p)
            {
            case 'u':
                t.uns64value = escapeSequence();
                tk = TOKwcharv;
                break;
            case 'U':
            case '&':
                t.uns64value = escapeSequence();
                tk = TOKdcharv;
                break;
            default:
                t.uns64value = escapeSequence();
                break;
            }
            break;
        case '\n':
        L1:
            endOfLine();
            goto case;
        case '\r':
            goto case '\'';
        case 0:
        case 0x1A:
            // decrement `p`, because it needs to point to the next token (the 0 or 0x1A character is the TOKeof token).
            p--;
            goto case;
        case '\'':
            error("unterminated character constant");
            t.uns64value = '?';
            return tk;
        default:
            if (c & 0x80)
            {
                p--;
                c = decodeUTF();
                p++;
                if (c == LS || c == PS)
                    goto L1;
                if (c < 0xD800 || (c >= 0xE000 && c < 0xFFFE))
                    tk = TOKwcharv;
                else
                    tk = TOKdcharv;
            }
            t.uns64value = c;
            break;
        }
        if (*p != '\'')
        {
            error("unterminated character constant");
            t.uns64value = '?';
            return tk;
        }
        p++;
        return tk;
    }

    /***************************************
     * Get postfix of string literal.
     */
    final void stringPostfix(Token* t)
    {
        switch (*p)
        {
        case 'c':
        case 'w':
        case 'd':
            t.postfix = *p;
            p++;
            break;
        default:
            t.postfix = 0;
            break;
        }
    }

    /**************************************
     * Read in a number.
     * If it's an integer, store it in tok.TKutok.Vlong.
     *      integers can be decimal, octal or hex
     *      Handle the suffixes U, UL, LU, L, etc.
     * If it's double, store it in tok.TKutok.Vdouble.
     * Returns:
     *      TKnum
     *      TKdouble,...
     */
    final TOK number(Token* t)
    {
        int base = 10;
        const start = p;
        uinteger_t n = 0; // unsigned >=64 bit integer type
        int d;
        bool err = false;
        bool overflow = false;
        dchar c = *p;
        if (c == '0')
        {
            ++p;
            c = *p;
            switch (c)
            {
            case '0':
            case '1':
            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
                n = c - '0';
                ++p;
                base = 8;
                break;
            case 'x':
            case 'X':
                ++p;
                base = 16;
                break;
            case 'b':
            case 'B':
                ++p;
                base = 2;
                break;
            case '.':
                if (p[1] == '.')
                    goto Ldone; // if ".."
                if (isalpha(p[1]) || p[1] == '_' || p[1] & 0x80)
                    goto Ldone; // if ".identifier" or ".unicode"
                goto Lreal; // '.' is part of current token
            case 'i':
            case 'f':
            case 'F':
                goto Lreal;
            case '_':
                ++p;
                base = 8;
                break;
            case 'L':
                if (p[1] == 'i')
                    goto Lreal;
                break;
            default:
                break;
            }
        }
        while (1)
        {
            c = *p;
            switch (c)
            {
            case '0':
            case '1':
                ++p;
                d = c - '0';
                break;
            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
                if (base == 2 && !err)
                {
                    error("binary digit expected");
                    err = true;
                }
                ++p;
                d = c - '0';
                break;
            case '8':
            case '9':
                ++p;
                if (base < 10 && !err)
                {
                    error("radix %d digit expected, not `%c`", base, c);
                    err = true;
                }
                d = c - '0';
                break;
            case 'a':
            case 'b':
            case 'c':
            case 'd':
            case 'e':
            case 'f':
            case 'A':
            case 'B':
            case 'C':
            case 'D':
            case 'E':
            case 'F':
                ++p;
                if (base != 16)
                {
                    if (c == 'e' || c == 'E' || c == 'f' || c == 'F')
                        goto Lreal;
                    if (!err)
                    {
                        error("radix %d digit expected, not `%c`", base, c);
                        err = true;
                    }
                }
                if (c >= 'a')
                    d = c + 10 - 'a';
                else
                    d = c + 10 - 'A';
                break;
            case 'L':
                if (p[1] == 'i')
                    goto Lreal;
                goto Ldone;
            case '.':
                if (p[1] == '.')
                    goto Ldone; // if ".."
                if (base == 10 && (isalpha(p[1]) || p[1] == '_' || p[1] & 0x80))
                    goto Ldone; // if ".identifier" or ".unicode"
                goto Lreal; // otherwise as part of a floating point literal
            case 'p':
            case 'P':
            case 'i':
            Lreal:
                p = start;
                return inreal(t);
            case '_':
                ++p;
                continue;
            default:
                goto Ldone;
            }
            // Avoid expensive overflow check if we aren't at risk of overflow
            if (n <= 0x0FFF_FFFF_FFFF_FFFFUL)
                n = n * base + d;
            else
            {
                import core.checkedint : mulu, addu;

                n = mulu(n, base, overflow);
                n = addu(n, d, overflow);
            }
        }
    Ldone:
        if (overflow && !err)
        {
            error("integer overflow");
            err = true;
        }
        enum FLAGS : int
        {
            FLAGS_none = 0,
            FLAGS_decimal = 1, // decimal
            FLAGS_unsigned = 2, // u or U suffix
            FLAGS_long = 4, // L suffix
        }

        alias FLAGS_none = FLAGS.FLAGS_none;
        alias FLAGS_decimal = FLAGS.FLAGS_decimal;
        alias FLAGS_unsigned = FLAGS.FLAGS_unsigned;
        alias FLAGS_long = FLAGS.FLAGS_long;

        FLAGS flags = (base == 10) ? FLAGS_decimal : FLAGS_none;
        // Parse trailing 'u', 'U', 'l' or 'L' in any combination
        const psuffix = p;
        while (1)
        {
            FLAGS f;
            switch (*p)
            {
            case 'U':
            case 'u':
                f = FLAGS_unsigned;
                goto L1;
            case 'l':
                f = FLAGS_long;
                error("lower case integer suffix 'l' is not allowed. Please use 'L' instead");
                goto L1;
            case 'L':
                f = FLAGS_long;
            L1:
                p++;
                if ((flags & f) && !err)
                {
                    error("unrecognized token");
                    err = true;
                }
                flags = cast(FLAGS)(flags | f);
                continue;
            default:
                break;
            }
            break;
        }
        if (base == 8 && n >= 8)
            error("octal literals `0%llo%.*s` are no longer supported, use `std.conv.octal!%llo%.*s` instead", n, p - psuffix, psuffix, n, p - psuffix, psuffix);
        TOK result;
        switch (flags)
        {
        case FLAGS_none:
            /* Octal or Hexadecimal constant.
             * First that fits: int, uint, long, ulong
             */
            if (n & 0x8000000000000000L)
                result = TOKuns64v;
            else if (n & 0xFFFFFFFF00000000L)
                result = TOKint64v;
            else if (n & 0x80000000)
                result = TOKuns32v;
            else
                result = TOKint32v;
            break;
        case FLAGS_decimal:
            /* First that fits: int, long, long long
             */
            if (n & 0x8000000000000000L)
            {
                if (!err)
                {
                    error("signed integer overflow");
                    err = true;
                }
                result = TOKuns64v;
            }
            else if (n & 0xFFFFFFFF80000000L)
                result = TOKint64v;
            else
                result = TOKint32v;
            break;
        case FLAGS_unsigned:
        case FLAGS_decimal | FLAGS_unsigned:
            /* First that fits: uint, ulong
             */
            if (n & 0xFFFFFFFF00000000L)
                result = TOKuns64v;
            else
                result = TOKuns32v;
            break;
        case FLAGS_decimal | FLAGS_long:
            if (n & 0x8000000000000000L)
            {
                if (!err)
                {
                    error("signed integer overflow");
                    err = true;
                }
                result = TOKuns64v;
            }
            else
                result = TOKint64v;
            break;
        case FLAGS_long:
            if (n & 0x8000000000000000L)
                result = TOKuns64v;
            else
                result = TOKint64v;
            break;
        case FLAGS_unsigned | FLAGS_long:
        case FLAGS_decimal | FLAGS_unsigned | FLAGS_long:
            result = TOKuns64v;
            break;
        default:
            debug
            {
                printf("%x\n", flags);
            }
            assert(0);
        }
        t.uns64value = n;
        return result;
    }

    /**************************************
     * Read in characters, converting them to real.
     * Bugs:
     *      Exponent overflow not detected.
     *      Too much requested precision is not detected.
     */
    final TOK inreal(Token* t)
    {
        //printf("Lexer::inreal()\n");
        debug
        {
            assert(*p == '.' || isdigit(*p));
        }
        bool isWellformedString = true;
        stringbuffer.reset();
        auto pstart = p;
        bool hex = false;
        dchar c = *p++;
        // Leading '0x'
        if (c == '0')
        {
            c = *p++;
            if (c == 'x' || c == 'X')
            {
                hex = true;
                c = *p++;
            }
        }
        // Digits to left of '.'
        while (1)
        {
            if (c == '.')
            {
                c = *p++;
                break;
            }
            if (isdigit(c) || (hex && isxdigit(c)) || c == '_')
            {
                c = *p++;
                continue;
            }
            break;
        }
        // Digits to right of '.'
        while (1)
        {
            if (isdigit(c) || (hex && isxdigit(c)) || c == '_')
            {
                c = *p++;
                continue;
            }
            break;
        }
        if (c == 'e' || c == 'E' || (hex && (c == 'p' || c == 'P')))
        {
            c = *p++;
            if (c == '-' || c == '+')
            {
                c = *p++;
            }
            bool anyexp = false;
            while (1)
            {
                if (isdigit(c))
                {
                    anyexp = true;
                    c = *p++;
                    continue;
                }
                if (c == '_')
                {
                    c = *p++;
                    continue;
                }
                if (!anyexp)
                {
                    error("missing exponent");
                    isWellformedString = false;
                }
                break;
            }
        }
        else if (hex)
        {
            error("exponent required for hex float");
            isWellformedString = false;
        }
        --p;
        while (pstart < p)
        {
            if (*pstart != '_')
                stringbuffer.writeByte(*pstart);
            ++pstart;
        }
        stringbuffer.writeByte(0);
        auto sbufptr = cast(const(char)*)stringbuffer.data;
        TOK result;
        bool isOutOfRange = false;
        t.floatvalue = (isWellformedString ? CTFloat.parse(sbufptr, &isOutOfRange) : CTFloat.zero);
        switch (*p)
        {
        case 'F':
        case 'f':
            if (isWellformedString && !isOutOfRange)
                isOutOfRange = Port.isFloat32LiteralOutOfRange(sbufptr);
            result = TOKfloat32v;
            p++;
            break;
        default:
            if (isWellformedString && !isOutOfRange)
                isOutOfRange = Port.isFloat64LiteralOutOfRange(sbufptr);
            result = TOKfloat64v;
            break;
        case 'l':
            error("use 'L' suffix instead of 'l'");
            goto case 'L';
        case 'L':
            result = TOKfloat80v;
            p++;
            break;
        }
        if (*p == 'i' || *p == 'I')
        {
            if (*p == 'I')
                error("use 'i' suffix instead of 'I'");
            p++;
            switch (result)
            {
            case TOKfloat32v:
                result = TOKimaginary32v;
                break;
            case TOKfloat64v:
                result = TOKimaginary64v;
                break;
            case TOKfloat80v:
                result = TOKimaginary80v;
                break;
            default:
                break;
            }
        }
        const isLong = (result == TOKfloat80v || result == TOKimaginary80v);
        if (isOutOfRange && !isLong)
        {
            const char* suffix = (result == TOKfloat32v || result == TOKimaginary32v) ? "f" : "";
            error(scanloc, "number `%s%s` is not representable", sbufptr, suffix);
        }
        debug
        {
            switch (result)
            {
            case TOKfloat32v:
            case TOKfloat64v:
            case TOKfloat80v:
            case TOKimaginary32v:
            case TOKimaginary64v:
            case TOKimaginary80v:
                break;
            default:
                assert(0);
            }
        }
        return result;
    }

    final Loc loc()
    {
        scanloc.charnum = cast(uint)(1 + p - line);
        return scanloc;
    }

    final void error(const(char)* format, ...)
    {
        va_list ap;
        va_start(ap, format);
        .verror(token.loc, format, ap);
        va_end(ap);
        errors = true;
    }

    final void error(Loc loc, const(char)* format, ...)
    {
        va_list ap;
        va_start(ap, format);
        .verror(loc, format, ap);
        va_end(ap);
        errors = true;
    }

    final void deprecation(const(char)* format, ...)
    {
        va_list ap;
        va_start(ap, format);
        .vdeprecation(token.loc, format, ap);
        va_end(ap);
        if (global.params.useDeprecated == 0)
            errors = true;
    }

    /*********************************************
     * parse:
     *      #line linnum [filespec]
     * also allow __LINE__ for linnum, and __FILE__ for filespec
     */
    final void poundLine()
    {
        auto linnum = this.scanloc.linnum;
        const(char)* filespec = null;
        const loc = this.loc();
        Token tok;
        scan(&tok);
        if (tok.value == TOKint32v || tok.value == TOKint64v)
        {
            const lin = cast(int)(tok.uns64value - 1);
            if (lin != tok.uns64value - 1)
                error("line number `%lld` out of range", cast(ulong)tok.uns64value);
            else
                linnum = lin;
        }
        else if (tok.value == TOKline)
        {
        }
        else
            goto Lerr;
        while (1)
        {
            switch (*p)
            {
            case 0:
            case 0x1A:
            case '\n':
            Lnewline:
                this.scanloc.linnum = linnum;
                if (filespec)
                    this.scanloc.filename = filespec;
                return;
            case '\r':
                p++;
                if (*p != '\n')
                {
                    p--;
                    goto Lnewline;
                }
                continue;
            case ' ':
            case '\t':
            case '\v':
            case '\f':
                p++;
                continue; // skip white space
            case '_':
                if (memcmp(p, "__FILE__".ptr, 8) == 0)
                {
                    p += 8;
                    filespec = mem.xstrdup(scanloc.filename);
                    continue;
                }
                goto Lerr;
            case '"':
                if (filespec)
                    goto Lerr;
                stringbuffer.reset();
                p++;
                while (1)
                {
                    uint c;
                    c = *p;
                    switch (c)
                    {
                    case '\n':
                    case '\r':
                    case 0:
                    case 0x1A:
                        goto Lerr;
                    case '"':
                        stringbuffer.writeByte(0);
                        filespec = mem.xstrdup(cast(const(char)*)stringbuffer.data);
                        p++;
                        break;
                    default:
                        if (c & 0x80)
                        {
                            uint u = decodeUTF();
                            if (u == PS || u == LS)
                                goto Lerr;
                        }
                        stringbuffer.writeByte(c);
                        p++;
                        continue;
                    }
                    break;
                }
                continue;
            default:
                if (*p & 0x80)
                {
                    uint u = decodeUTF();
                    if (u == PS || u == LS)
                        goto Lnewline;
                }
                goto Lerr;
            }
        }
    Lerr:
        error(loc, "#line integer [\"filespec\"]\\n expected");
    }

    /********************************************
     * Decode UTF character.
     * Issue error messages for invalid sequences.
     * Return decoded character, advance p to last character in UTF sequence.
     */
    final uint decodeUTF()
    {
        const s = p;
        assert(*s & 0x80);
        // Check length of remaining string up to 6 UTF-8 characters
        size_t len;
        for (len = 1; len < 6 && s[len]; len++)
        {
        }
        size_t idx = 0;
        dchar u;
        const msg = utf_decodeChar(s, len, idx, u);
        p += idx - 1;
        if (msg)
        {
            error("%s", msg);
        }
        return u;
    }

    /***************************************************
     * Parse doc comment embedded between t.ptr and p.
     * Remove trailing blanks and tabs from lines.
     * Replace all newlines with \n.
     * Remove leading comment character from each line.
     * Decide if it's a lineComment or a blockComment.
     * Append to previous one for this token.
     *
     * If newParagraph is true, an extra newline will be
     * added between adjoining doc comments.
     */
    final void getDocComment(Token* t, uint lineComment, bool newParagraph)
    {
        /* ct tells us which kind of comment it is: '/', '*', or '+'
         */
        const ct = t.ptr[2];
        /* Start of comment text skips over / * *, / + +, or / / /
         */
        const(char)* q = t.ptr + 3; // start of comment text
        const(char)* qend = p;
        if (ct == '*' || ct == '+')
            qend -= 2;
        /* Scan over initial row of ****'s or ++++'s or ////'s
         */
        for (; q < qend; q++)
        {
            if (*q != ct)
                break;
        }
        /* Remove leading spaces until start of the comment
         */
        int linestart = 0;
        if (ct == '/')
        {
            while (q < qend && (*q == ' ' || *q == '\t'))
                ++q;
        }
        else if (q < qend)
        {
            if (*q == '\r')
            {
                ++q;
                if (q < qend && *q == '\n')
                    ++q;
                linestart = 1;
            }
            else if (*q == '\n')
            {
                ++q;
                linestart = 1;
            }
        }
        /* Remove trailing row of ****'s or ++++'s
         */
        if (ct != '/')
        {
            for (; q < qend; qend--)
            {
                if (qend[-1] != ct)
                    break;
            }
        }
        /* Comment is now [q .. qend].
         * Canonicalize it into buf[].
         */
        OutBuffer buf;

        void trimTrailingWhitespace()
        {
            const s = buf.peekSlice();
            auto len = s.length;
            while (len && (s[len - 1] == ' ' || s[len - 1] == '\t'))
                --len;
            buf.setsize(len);
        }

        for (; q < qend; q++)
        {
            char c = *q;
            switch (c)
            {
            case '*':
            case '+':
                if (linestart && c == ct)
                {
                    linestart = 0;
                    /* Trim preceding whitespace up to preceding \n
                     */
                    trimTrailingWhitespace();
                    continue;
                }
                break;
            case ' ':
            case '\t':
                break;
            case '\r':
                if (q[1] == '\n')
                    continue; // skip the \r
                goto Lnewline;
            default:
                if (c == 226)
                {
                    // If LS or PS
                    if (q[1] == 128 && (q[2] == 168 || q[2] == 169))
                    {
                        q += 2;
                        goto Lnewline;
                    }
                }
                linestart = 0;
                break;
            Lnewline:
                c = '\n'; // replace all newlines with \n
                goto case;
            case '\n':
                linestart = 1;
                /* Trim trailing whitespace
                 */
                trimTrailingWhitespace();
                break;
            }
            buf.writeByte(c);
        }
        /* Trim trailing whitespace (if the last line does not have newline)
         */
        trimTrailingWhitespace();

        // Always end with a newline
        const s = buf.peekSlice();
        if (s.length == 0 || s[$ - 1] != '\n')
            buf.writeByte('\n');

        // It's a line comment if the start of the doc comment comes
        // after other non-whitespace on the same line.
        auto dc = (lineComment && anyToken) ? &t.lineComment : &t.blockComment;
        // Combine with previous doc comment, if any
        if (*dc)
            *dc = combineComments(*dc, buf.peekString(), newParagraph);
        else
            *dc = buf.extractString();
    }

    /********************************************
     * Combine two document comments into one,
     * separated by an extra newline if newParagraph is true.
     */
    static const(char)* combineComments(const(char)* c1, const(char)* c2, bool newParagraph)
    {
        //printf("Lexer::combineComments('%s', '%s', '%i')\n", c1, c2, newParagraph);
        auto c = c2;
        const(int) newParagraphSize = newParagraph ? 1 : 0; // Size of the combining '\n'
        if (c1)
        {
            c = c1;
            if (c2)
            {
                size_t len1 = strlen(c1);
                size_t len2 = strlen(c2);
                int insertNewLine = 0;
                if (len1 && c1[len1 - 1] != '\n')
                {
                    ++len1;
                    insertNewLine = 1;
                }
                auto p = cast(char*)mem.xmalloc(len1 + newParagraphSize + len2 + 1);
                memcpy(p, c1, len1 - insertNewLine);
                if (insertNewLine)
                    p[len1 - 1] = '\n';
                if (newParagraph)
                    p[len1] = '\n';
                memcpy(p + len1 + newParagraphSize, c2, len2);
                p[len1 + newParagraphSize + len2] = 0;
                c = p;
            }
        }
        return c;
    }

private:
    final void endOfLine()
    {
        scanloc.linnum++;
        line = p;
    }
}
