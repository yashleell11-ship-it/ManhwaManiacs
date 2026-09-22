"use client";

import { useState } from "react";
import { Sparkles } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  canSubmitPrompt,
  MAX_PROMPT_LENGTH,
} from "@/features/library/suggestions";

/**
 * The "describe what you feel like reading" input.
 *
 * Fires on explicit submit only — never on keystroke, never on mount. One
 * submit is one paid API call on the server, which is the whole reason this is
 * a textarea with a button rather than the debounced live-search field two
 * screens over.
 */
interface SuggestionPromptBoxProps {
  onSubmit: (prompt: string) => void;
  isPending: boolean;
  /** Requests left in today's allowance, shown once it gets low. */
  remainingToday?: number;
}

/**
 * Concrete enough to show the box takes a sentence, not a keyword. Shown
 * "action, fantasy" a reader types "action, fantasy" and has reinvented
 * search — the examples are what teach the difference.
 */
const EXAMPLES = [
  "A murim regressor who comes back stronger",
  "Magic academy, but the lead is already strong",
  "Something slow and political, not a power fantasy",
] as const;

export function SuggestionPromptBox({
  onSubmit,
  isPending,
  remainingToday,
}: SuggestionPromptBoxProps) {
  const [prompt, setPrompt] = useState("");

  const submit = (text: string) => {
    if (!canSubmitPrompt(text, isPending)) return;
    onSubmit(text.trim());
  };

  return (
    <div className="mb-8">
      <textarea
        value={prompt}
        onChange={(event) => setPrompt(event.target.value.slice(0, MAX_PROMPT_LENGTH))}
        onKeyDown={(event) => {
          // Enter submits, Shift+Enter writes a newline — the convention for a
          // box that is a question rather than a document.
          if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            submit(prompt);
          }
        }}
        rows={3}
        placeholder="e.g. a revenge story with a competent lead, no harem"
        aria-label="Describe what you feel like reading"
        className="w-full resize-y rounded-2xl border border-border/50 bg-white/[0.03] p-4 text-base text-fg placeholder:text-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
      />

      <div className="mt-3 flex flex-wrap gap-2">
        {EXAMPLES.map((example) => (
          <button
            key={example}
            type="button"
            disabled={isPending}
            onClick={() => {
              setPrompt(example);
              submit(example);
            }}
            className="rounded-full border border-border/50 bg-white/[0.03] px-3 py-1.5 text-xs text-muted transition-colors hover:border-primary/40 hover:bg-primary/10 hover:text-primary disabled:opacity-50"
          >
            {example}
          </button>
        ))}
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Button onClick={() => submit(prompt)} disabled={!canSubmitPrompt(prompt, isPending)}>
          <Sparkles className="size-4" aria-hidden />
          {isPending ? "Thinking…" : "Suggest something"}
        </Button>
        {typeof remainingToday === "number" && remainingToday <= 10 ? (
          <span className="text-xs text-muted">
            {remainingToday} left today
          </span>
        ) : null}
      </div>
    </div>
  );
}
