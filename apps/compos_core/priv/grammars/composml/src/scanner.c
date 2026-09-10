#include "tree_sitter/parser.h"
#include <stdlib.h>
enum TokenType { STYLE_TEXT, SCRIPT_TEXT };
void *tree_sitter_composml_external_scanner_create(void) { return NULL; }
void tree_sitter_composml_external_scanner_destroy(void *payload) {}
unsigned tree_sitter_composml_external_scanner_serialize(void *payload, char *buffer) { return 0; }
void tree_sitter_composml_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {}
// Raw CSS/JS ends at its closing element or an EEx interpolation.
bool tree_sitter_composml_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid) {
  if (valid[STYLE_TEXT] == valid[SCRIPT_TEXT]) return false;
  const char *close = valid[STYLE_TEXT] ? "/style" : "/script";
  lexer->result_symbol = valid[STYLE_TEXT] ? STYLE_TEXT : SCRIPT_TEXT;
  bool content = false;
  while (!lexer->eof(lexer)) {
    lexer->mark_end(lexer);
    if (lexer->lookahead == '<') {
      lexer->advance(lexer, false);
      if (lexer->lookahead == '%') return content;
      unsigned i = 0;
      while (close[i] && lexer->lookahead == close[i]) { lexer->advance(lexer, false); i++; }
      if (!close[i] && (lexer->lookahead == '>' || lexer->lookahead == ' ' || lexer->lookahead == '\n')) return content;
      content = true;
    } else { lexer->advance(lexer, false); content = true; }
  }
  lexer->mark_end(lexer);
  return content;
}
