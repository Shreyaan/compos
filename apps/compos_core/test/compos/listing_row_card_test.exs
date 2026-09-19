defmodule Compos.ListingRowCardTest do
  @moduledoc """
  Moving between the rows of ibuffer and of the chat list floats the row's
  card (the owner's ruling: a list row's preview is the floating card). The
  move goes through KeyDispatch with a key the test binds itself to the
  list's own motion command.
  """
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}

  defp eval!(code, frame) do
    assert {:ok, result} = Session.eval(code, frame)
    result
  end

  # the card is up and shows a copy of the row the point is on
  defp card_follows_row?(frame) do
    Enum.any?(1..40, fn _ ->
      Process.sleep(50)

      eval!(
        """
        (let ((row (list-current *zz-card-owner*)) (b (float-buffer)))
          (and (float-open?) (string? b) (string-prefix? " *listing-preview" b)
               (buffer-known? b) (string? row)
               (equal? (buffer-local b 'listing-preview-source) row)))
        """,
        frame
      ) == "#t"
    end)
  end

  for {name, open} <- [
        {"ibuffer", ~s{(run-command "ibuffer")}},
        {"the chat list", ~s{(run-command "chat-list")}}
      ] do
    @open open
    test "moving between #{name} rows floats each row's card" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)

      try do
        eval!(
          """
          (for-each (lambda (b)
                      (test-buffer! b (string-append "body of " b))
                      (buffer-set-local! b 'mode-name "chat-mode"))
                    '("*zz-card-a*" "*zz-card-b*" "*zz-card-c*"))
          (delete-other-windows!)
          (switch-to-buffer-here! "*zz-card-a*")
          #{@open}
          (define *zz-card-owner* (current-buffer))
          (list-set-filters! *zz-card-owner* (list (list "match" "zz-card-")))
          (list-refresh! *zz-card-owner*)
          (ibuffer-goto-first-row! *zz-card-owner*)
          (local-set-key* *zz-card-owner* "<f9> n" "next-line")
          """,
          frame
        )

        for _ <- 1..2 do
          KeyDispatch.handle_key(frame, "<f9>")
          KeyDispatch.handle_key(frame, "n")
          assert card_follows_row?(frame), "the card shows the row after the move"
        end
      after
        eval!(
          """
          (when (boundp '*zz-card-owner*) (listing-preview-dismiss! *zz-card-owner*))
          (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                    '("*zz-card-a*" "*zz-card-b*" "*zz-card-c*"))
          """,
          frame
        )

        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end
end
