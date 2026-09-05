// Three questions the grammar cannot ask, because each one is answered
// by what comes AFTER the token: where a chat name ends (at the next
// " From: "), where a sender ends (at the next ":"), and where a body
// ends (at the newline before the next message header).

#include "tree_sitter/parser.h"

enum TokenType {
  CHAT_TEXT,
  SENDER_TEXT,
  BODY_TEXT,
};

static bool is_digit(int32_t c) { return c >= '0' && c <= '9'; }

// Read LITERAL if it stands here. What it reads stays read either way:
// the caller only asks at a point where the characters belong to the
// token anyway, so a half match costs nothing.
static bool eat(TSLexer *lexer, const char *literal, unsigned *read) {
  for (const char *c = literal; *c; c++) {
    if (lexer->lookahead != (int32_t)*c) return false;
    lexer->advance(lexer, false);
    (*read)++;
  }
  return true;
}

// "[2026-09-04 11:18:33]" — the shape that opens a message.
static bool header_ahead(TSLexer *lexer) {
  if (lexer->lookahead != '[') return false;
  lexer->advance(lexer, false);
  for (const char *c = "dddd-dd-dd dd:dd:dd]"; *c; c++) {
    if (*c == 'd') {
      if (!is_digit(lexer->lookahead)) return false;
    } else if (lexer->lookahead != (int32_t)*c) {
      return false;
    }
    lexer->advance(lexer, false);
  }
  return true;
}

// A chat name runs to the " From: " that follows it, and holds spaces
// of its own until then.
static bool scan_chat(TSLexer *lexer) {
  unsigned read = 0;
  for (;;) {
    if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
    if (lexer->lookahead == ' ') {
      unsigned before = read;
      lexer->mark_end(lexer);
      if (eat(lexer, " From: ", &read)) {
        lexer->result_symbol = CHAT_TEXT;
        return before > 0;
      }
      continue;
    }
    lexer->advance(lexer, false);
    read++;
  }
}

// A sender runs to the colon that introduces the body. A name with a
// colon in it would end early, which is the reading the plain-text
// transcript offers too.
static bool scan_sender(TSLexer *lexer) {
  unsigned read = 0;
  while (!lexer->eof(lexer) && lexer->lookahead != ':'
         && lexer->lookahead != '\n') {
    lexer->advance(lexer, false);
    read++;
  }
  if (read == 0) return false;
  lexer->mark_end(lexer);
  lexer->result_symbol = SENDER_TEXT;
  return true;
}

// A body runs to the newline before the next header, so it keeps the
// newlines a multi-line message was sent with. A body of nothing is no
// body: the grammar has it optional, and the blank rule takes the rest
// of the line.
static bool scan_body(TSLexer *lexer) {
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t') {
    lexer->advance(lexer, true);
  }
  if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
  lexer->result_symbol = BODY_TEXT;
  for (;;) {
    if (lexer->eof(lexer)) {
      lexer->mark_end(lexer);
      return true;
    }
    if (lexer->lookahead == '\n') {
      lexer->mark_end(lexer);
      lexer->advance(lexer, false);
      if (header_ahead(lexer)) return true;
      // not a header: the newline, and whatever the look ahead read,
      // are the body's own
      if (lexer->eof(lexer)) {
        lexer->mark_end(lexer);
        return true;
      }
      continue;
    }
    lexer->advance(lexer, false);
  }
}

bool tree_sitter_whatsapp_external_scanner_scan(void *payload, TSLexer *lexer,
                                               const bool *valid_symbols) {
  // Recovery asks for every token at once. None of these three can be
  // recognised out of place, so answer nothing and let the parser skip.
  if (valid_symbols[CHAT_TEXT] && valid_symbols[SENDER_TEXT]
      && valid_symbols[BODY_TEXT]) {
    return false;
  }
  if (valid_symbols[CHAT_TEXT]) return scan_chat(lexer);
  if (valid_symbols[SENDER_TEXT]) return scan_sender(lexer);
  if (valid_symbols[BODY_TEXT]) return scan_body(lexer);
  return false;
}

// The scanner keeps nothing between calls, so there is nothing to move
// across a serialize boundary.
void *tree_sitter_whatsapp_external_scanner_create(void) { return NULL; }
void tree_sitter_whatsapp_external_scanner_destroy(void *payload) {}
unsigned tree_sitter_whatsapp_external_scanner_serialize(void *payload,
                                                        char *buffer) {
  return 0;
}
void tree_sitter_whatsapp_external_scanner_deserialize(void *payload,
                                                       const char *buffer,
                                                       unsigned length) {}
