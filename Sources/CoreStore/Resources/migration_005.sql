-- Migration 5 — a verdict on a saved answer.
--
-- Every retrieval constant in this project rests on 20 hand-written benchmark cases:
-- denseWeight 0, mmrLambda 0.85, the finding that fusion beats its own legs. Twenty cases,
-- one corpus, binary judgements. That is a thin foundation for the weight put on it, and it is
-- thin because writing cases by hand is expensive.
--
-- Migration 4 started persisting every question, its answer, its sources and its receipt. This
-- adds the one missing column that turns that history into a corpus: whether the answer was
-- any good. The expensive part of an eval set is not the harness, it is the labelled examples,
-- and the cheapest possible way to collect them is to let ordinary use produce them.
--
-- NULL is the honest default and must stay reachable. An unjudged answer is unmeasured, not
-- neutral, and an eval built from "everything nobody complained about" would be a different
-- and much worse thing than one built from what a person actually marked.

ALTER TABLE conversation_turn ADD COLUMN judgement TEXT;

-- When, so a judgement can be read as evidence about the system *at that time*. Retrieval
-- tuning changes; a verdict from before a change does not describe the pipeline after it.
ALTER TABLE conversation_turn ADD COLUMN judged_at REAL;

CREATE INDEX IF NOT EXISTS idx_turn_judgement ON conversation_turn(judgement) WHERE judgement IS NOT NULL;
