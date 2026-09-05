/// The transcript the whatsapp MCP server prints, as a tree.
///
/// One line opens a message, and every line after it belongs to that
/// message until the next line opens one:
///
///   [2026-09-04 11:18:33] Chat: Gargi From: Gargi: Hello sir
///   a second line of the same message
///   [2026-09-04 11:55:38] Chat: Gargi From: Me: on its way
///
/// A chat name holds spaces and a body holds newlines, so where the
/// chat ends and where the body ends are both decided by what comes
/// after — a question no regular expression here can ask. src/scanner.c
/// answers those three, and the grammar answers the rest.

module.exports = grammar({
  name: 'whatsapp',

  // Nothing between tokens is insignificant: the leading space belongs
  // to ' Chat: ' and a trailing one belongs to the body.
  extras: () => [],

  externals: $ => [$._chat_text, $._sender_text, $._body_text],

  rules: {
    conversation: $ => repeat($.message),

    message: $ => seq(
      '[', field('time', $.timestamp), ']',
      ' Chat: ', field('chat', $.chat),
      ' From: ', field('sender', $.sender), ':',
      optional(field('body', $.body)),
      optional($._blank),
    ),

    timestamp: () => /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/,

    chat: $ => $._chat_text,
    sender: $ => $._sender_text,
    body: $ => $._body_text,

    // the end of a message; a body of nothing but spaces never becomes
    // a node, so those spaces end up here
    _blank: () => /[ \t]*\n+/,
  },
});
