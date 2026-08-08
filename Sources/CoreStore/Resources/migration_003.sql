-- Migration 3 — per-source configuration.
--
-- Connectors that need setup (an MCP server's command, its allowlisted tools, which
-- environment variables to forward) had nowhere to keep it. This adds one JSON column
-- rather than a table per connector kind, because the shape genuinely differs per kind
-- and a shared table would be a union of unrelated columns, most of them NULL.
--
-- SECURITY: this column stores environment variable *names*, never their values. A server
-- needing SLACK_TOKEN records the string "SLACK_TOKEN"; the value is read from the process
-- environment at launch. Nothing here is a place a credential may be written, and the
-- database is not encrypted.

ALTER TABLE source ADD COLUMN config TEXT;
