# Peek

A peek is a look at a buffer without keeping it. `RET` on a row in dired or the switcher peeks. The rules live in `scheme/packages/window.scm` (the peek section) and here.

A row whose detail is a buffer you mean to keep is not a peek: that is the detail window (`scheme/packages/detail.scm`, docs/DISPLAY-BUFFER.md). It borrows the peek's discipline of one remembered window and nothing else.

## Rules

1. A peek is a display of category `preview` (docs/DISPLAY-BUFFER.md). By the stock rule it goes through the window chain: it takes a window that is not the reader's, so it never covers the listing. The next peek takes that same window, and dismissing it puts the window back. A rule of your own, `(add-display-rule! '(category preview) 'popup)`, sends it to the popup instead, on the side away from the window it was asked from. A peek takes no focus: the buffer is set in the window in place, the selection moves nowhere, and `other-window` and the focus chords pass its window by (`M-<down>` scrolls it; `RET` on its row opens it, and only then is it a window you can enter).
2. One peek at a time. The next peek replaces the last one. A buffer that a peek made is killed when it is replaced, and it never waits on the popup stack; a buffer that existed before the peek is only shown, never killed. One peek buffer lives at a time; recent keeps names only, fifty at most.
3. A peek is read-only. `peek-mode` is a minor mode: its setup makes the buffer read-only and records the state it had; keep puts that state back. The mode is saved with the buffer, so a peek on screen at a restart comes back as a peek.
4. Open is `RET` again on the row, or `M-RET` (`peek-open!`): the mark goes, the peek window gives the buffer up, and the selected window shows it as a visit would. `M-x keep-buffer` keeps without opening; a change from outside the keyboard (an agent's edit) keeps too.
5. `q` on the peek dismisses it (the read-only keymap binds it). `q` anywhere else (`quit-window`) dismisses a peek that shows before it does anything else: in dired, ibuffer, or any listing, the first `q` takes the peek and the next one the listing. A dismissed peek leaves a row in recent; the switcher lists recent below the live buffers and hides live peeks.
6. Browse keeps its own chord: `M-RET` on a link peeks it, and `M-RET` on the same link keeps it.
7. In dired a look opens on `RET` only. While a peek shows, the highlight drives it: rest on a file (`dired-peek-ms`, 120 ms) and the peek window shows that file instead, and `RET` on it opens. A rest fires only if the reader is still in the listing. With no peek showing, moving the highlight shows nothing. `dired-peek-on-move` turns the following off. A peek opens the file quietly (`visit-quietly`): the selected window never shows it on the way to the peek window.
8. `M-<down>` and `M-<up>` from the listing scroll the peek: `scroll-other-window` and `scroll-other-window-down` read the look beside your work (a peek, the messages, the telemetry) before the next window.
9. A peek does not touch the MRU ring. The ring records the buffers the reader used, and a look is not a use. `peek-show!` sets `*display-preview*`, and the display then sets the window's buffer through `window-preview-buffer!`, which changes the window and leaves the ring alone. A list that reads the ring shows why: the buffer table and the chat table sort their rows by recency, and a peek that bumped the ring reordered the rows under the point. Keeping the peek is a use, and the ring records that.

Tests: `scheme/packages/peek-test.scm`, `scheme/packages/peek-md-test.scm`, run by the package suite (`test/compos/package_suite_test.exs`, `--include packages`).
