/**
 * Pure helpers for /relaunch: the argument parser, the helper script's JSON
 * line, the model check and the welcome-back record. No `$` here, so the
 * tests import them directly.
 */

/** What the first word of `/relaunch ...` picks; `ask` when it is none. */
export type Mode = 'ask' | 'now' | 'compact' | 'stay' | 'help'

export type RelaunchArgs = { mode: Mode; note: string }

const KEYWORDS: readonly Mode[] = ['now', 'compact', 'stay', 'help']

/**
 * Splits `/relaunch` arguments into an optional leading keyword and a note.
 *
 * Only the first word is a keyword (any case); everything after it is the
 * note, verbatim. Text that does not start with a keyword is all note and
 * leaves the mode at `ask`, so a typo like `/relaunch stya` still goes
 * through the confirm dialog instead of relaunching on the spot.
 *
 * @param raw everything after `/relaunch`
 */
export function parseArgs(raw: string): RelaunchArgs {
  const text = raw.trim()
  const match = /^(\S+)\s*([\s\S]*)$/.exec(text)

  if (!match) {
    return { mode: 'ask', note: '' }
  }

  const first = match[1].toLowerCase()

  if (first === '?' || first === '-h' || first === '--help') {
    return { mode: 'help', note: '' }
  }

  if ((KEYWORDS as readonly string[]).includes(first)) {
    return { mode: first as Mode, note: match[2].trim() }
  }

  return { mode: 'ask', note: text }
}

export type LaunchResult =
  | { ok: true; pid: number; terminal: string; exe: string; args: string[]; title: string }
  | { ok: false; error: string }

/** The helper's one JSON line, or a failure naming what it printed instead. */
export function parseLaunch(stdout: string, stderr: string): LaunchResult {
  const line = stdout.trim().split(/\r?\n/).at(-1) ?? ''

  try {
    const parsed = JSON.parse(line) as Partial<LaunchResult> & { ok?: unknown }

    if (parsed.ok === true || parsed.ok === false) {
      return parsed as LaunchResult
    }
  } catch {
    // Fall through to the failure below.
  }

  return { ok: false, error: (stderr || stdout || 'relaunch.ps1 printed nothing').trim() }
}

/** `exe args...` as one line, quoting the parts that hold spaces. */
export function commandLine(exe: string, args: readonly string[]): string {
  return [exe, ...args].map(part => (/\s/.test(part) || part === '' ? `"${part}"` : part)).join(' ')
}

/**
 * Whether `$.session.model()`'s answer can go to `--model` as is.
 *
 * Probed on 2.1.288 it is the model id (`claude-opus-5-5`); an alias
 * (`opus`), a provider id (`us.anthropic.claude-...`) or a `[1m]` suffix also
 * pass. A display name (`Opus 5.5`, anything with spaces or brackets other
 * than the suffix) does not, so the new session keeps its original flags.
 *
 * @param model what `$.session.model()` returned
 */
export function isModelFlag(model: string | undefined | null): model is string {
  return typeof model === 'string' && /^[A-Za-z0-9][\w.:/@-]*(\[1m\])?$/.test(model) && model.length <= 200
}

/** What /relaunch leaves in the store for the session it reopens. */
export type PendingRecord = { id: string; at: number; note: string; ttlMs: number }

/** How long a record stays good after `/relaunch` and `/relaunch compact`. */
export const PENDING_TTL_MS = 10 * 60 * 1000

/** `/relaunch stay` waits for the person to /exit, which can take hours. */
export const PENDING_STAY_TTL_MS = 12 * 60 * 60 * 1000

/** The store key of one session's record. */
export const PENDING_PREFIX = 'pending.'

/** Narrows a store value to a record; anything else reads as none. */
export function asPending(value: unknown): PendingRecord | null {
  if (!value || typeof value !== 'object') {
    return null
  }

  const record = value as Record<string, unknown>

  if (typeof record.id !== 'string' || typeof record.at !== 'number') {
    return null
  }

  return {
    id: record.id,
    at: record.at,
    note: typeof record.note === 'string' ? record.note : '',
    ttlMs: typeof record.ttlMs === 'number' ? record.ttlMs : PENDING_TTL_MS,
  }
}

/** Whether a record is still within its time to live at `now`. */
export function isFresh(record: PendingRecord, now: number): boolean {
  return now >= record.at && now - record.at <= record.ttlMs
}
