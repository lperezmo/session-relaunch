/**
 * session-relaunch: `/relaunch` restarts this session in a new terminal tab
 * with `claude --resume <id>`, so MCP servers added since it started load.
 *
 * Steps: optionally compact, have relaunch.ps1 open a tab that waits for this
 * claude.exe to exit and then resumes the same session id with the same flags
 * (plus the current model when /model changed it), leave a record in the
 * store for the new process to welcome itself back with, then exit this one.
 * Resuming by id rather than `--continue` picks the right session when
 * several are open at once.
 *
 * Also nudges the person (never the model) when a tool call changes the MCP
 * configuration, since that is exactly when a relaunch is needed.
 *
 * Every `$.noun.verb(...)` is written literally here; the loader inventories
 * them statically. The helpers in parse.ts and mcp-change.ts take no `$`.
 */

import type { EngineInterface, On } from 'claude-code'

import { mcpChange } from './mcp-change'
import {
  asPending,
  commandLine,
  isFresh,
  isModelFlag,
  parseArgs,
  parseLaunch,
  PENDING_PREFIX,
  PENDING_STAY_TTL_MS,
  PENDING_TTL_MS,
  type Mode,
  type PendingRecord,
} from './parse'

const COMMAND_NAME = 'relaunch'

export const USAGE = [
  'Usage: /relaunch [now|compact|stay] [note...]',
  '  /relaunch                 ask: relaunch now, compact first, or open the tab and stay',
  '  /relaunch now [note]      reopen this session in a new tab and exit this one',
  '  /relaunch compact [note]  compact first (the note also steers the summary), then relaunch',
  '  /relaunch stay [note]     open the new tab but leave this session running (it starts once you /exit)',
  '  /relaunch <note>          text without a keyword is a note; it still asks first',
  'The note is put in the new session\'s prompt box. /relaunch help shows this.',
].join('\n')

/** The confirm dialog's labels and the mode each one picks. */
const CHOICES: Record<string, Exclude<Mode, 'ask' | 'help'>> = {
  'Relaunch now': 'now',
  'Compact, then relaunch': 'compact',
  'Open tab, stay here': 'stay',
}

const CANCEL = 'Cancel'

/** How long a relaunch waits for this process to exit before giving up. */
const WAIT_SECONDS = 120

/**
 * `$.command.run` from inside a `command.run` hook is refused (it would wait
 * on the turn the hook holds), so `/exit` runs from a timer just after
 * /relaunch has answered.
 */
const EXIT_DELAY_MS = 300

/** The welcome waits for the REPL to mount: first try, retries, spacing. */
const WELCOME_DELAY_MS = 1000
const WELCOME_RETRIES = 10
const WELCOME_RETRY_MS = 500

/**
 * Runs `/exit` once the current command has returned, saying so in the
 * transcript if it is refused.
 *
 * @param $ the engine interface
 * @param opened the line /relaunch answered with, repeated in the fallback
 */
function exitSoon($: EngineInterface, opened: string) {
  $.clock.after(EXIT_DELAY_MS, () => {
    $.command.run({ command: 'exit' }).catch((error: unknown) => {
      const reason = error instanceof Error ? error.message : String(error)

      $.ui.log(opened)
      $.ui.log(`Could not exit this session automatically (${reason}); type /exit and the new tab takes over.`)
    })
  })
}

type Launched = { ok: true; opened: string } | { ok: false; text: string }

/**
 * Opens the new tab through relaunch.ps1 and leaves the welcome-back record.
 *
 * @param $ the engine interface
 * @param stay whether the new tab waits for this session without a time limit
 * @param note the note for the new session's prompt box, possibly empty
 * @param startModel the model the session started on, so only a change is carried
 */
async function launch($: EngineInterface, stay: boolean, note: string, startModel: string | undefined): Promise<Launched> {
  const sessionId = await $.session.id()
  const cwd = await $.session.cwd()
  const model = await $.session.model()
  const script = `${$.plugin.root}\\hooks\\relaunch.ps1`

  const argv = [
    'powershell.exe',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script,
    '-SessionId',
    sessionId,
    '-Cwd',
    cwd,
    '-WaitSeconds',
    String(stay ? 0 : WAIT_SECONDS),
  ]

  if (isModelFlag(model) && model !== startModel) {
    argv.push('-Model', model)
  }

  const run = await $.process.run(argv)
  const result = parseLaunch(run.stdout, run.stderr)

  if (!result.ok) {
    return { ok: false, text: `/relaunch could not open the new tab: ${result.error}` }
  }

  const record: PendingRecord = {
    id: sessionId,
    at: await $.clock.now(),
    note,
    ttlMs: stay ? PENDING_STAY_TTL_MS : PENDING_TTL_MS,
  }

  await $.store.set(`${PENDING_PREFIX}${sessionId}`, record)

  return { ok: true, opened: `Opened a new tab (${result.title}) running: ${commandLine(result.exe, result.args)}` }
}

/**
 * Compacts, then relaunches, once /relaunch has answered: the host refuses
 * `$.session.compact` from inside a `command.run` hook (it would compact under
 * the turn the hook holds). Progress goes to the transcript as `ui.log` lines,
 * one call per line since a log line does not break on `\n`.
 * The note doubles as the compaction instructions, like `/compact <text>`.
 *
 * @param $ the engine interface
 * @param note the summary instructions and the new prompt box text, possibly empty
 * @param startModel the model the session started on
 */
async function compactThenRelaunch($: EngineInterface, note: string, startModel: string | undefined) {
  try {
    const { skip } = await $.session.compact(note ? { instructions: note } : undefined)

    if (skip) {
      $.ui.log('Compaction was vetoed by a hook, so nothing was relaunched.')

      return
    }

    const launched = await launch($, false, note, startModel)

    if (!launched.ok) {
      $.ui.log(launched.text)

      return
    }

    $.ui.log(launched.opened)
    $.ui.log('Exiting this session...')
    exitSoon($, launched.opened)
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error)

    $.ui.log(`/relaunch compact failed (${reason}). Run /compact, then /relaunch now.`)
  }
}

/**
 * Shows the welcome-back toast and puts the note in the prompt box, retrying
 * while the REPL is still mounting or a dialog holds the keys.
 *
 * @param $ the engine interface
 * @param note the note left by /relaunch, possibly empty
 * @param attempt how many tries came before this one
 */
async function welcome($: EngineInterface, note: string, attempt: number) {
  try {
    const surfaces = await $.session.surfaces()
    const filled = note && surfaces.includes('terminal') ? await $.prompt.fill({ text: note }) : null
    const ready = surfaces.includes('terminal') && (!filled || filled.isFilled || !filled.refusal)

    if (!ready && attempt < WELCOME_RETRIES) {
      $.clock.after(WELCOME_RETRY_MS, () => void welcome($, note, attempt + 1))

      return
    }

    $.ui.toast('Resumed via /relaunch')
  } catch (error) {
    $.ui.log(`session-relaunch welcome failed: ${String(error)}`, { to: 'debug' })
  }
}

/**
 * Registers the command, the welcome back and the MCP-change nudge.
 *
 * @param on the engine's registrar
 */
export function register(on: On) {
  // The model the session started on, so only a mid-session /model change
  // is carried to the new process; its own flags already cover the rest.
  let startModel: string | undefined

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND_NAME,
      description: 'Restart this session in a new tab (--resume) so new MCP servers load',
      argumentHint: '[now|compact|stay] [note]',
    })

    startModel = await $.session.model()

    // A headless resume of the same id leaves the record for the real one.
    if (!e.isInteractive) {
      return next(e)
    }

    const id = await $.session.id()
    const now = await $.clock.now()
    let mine: PendingRecord | null = null

    for (const key of await $.store.keys()) {
      if (!key.startsWith(PENDING_PREFIX)) {
        continue
      }

      const record = asPending(await $.store.get(key))
      const isMine = record?.id === id && key === `${PENDING_PREFIX}${id}`

      if (isMine && record && isFresh(record, now)) {
        mine = record
      }

      if (isMine || !record || !isFresh(record, now)) {
        await $.store.delete(key)
      }
    }

    if (mine) {
      const note = mine.note

      $.clock.after(WELCOME_DELAY_MS, () => void welcome($, note, 0))
    }

    return next(e)
  })

  on('command.run', { command: COMMAND_NAME }, async ($, e, next) => {
    const parsed = parseArgs(e.args)

    if (parsed.mode === 'help') {
      return { text: USAGE }
    }

    const surfaces = await $.session.surfaces()

    if (!surfaces.includes('terminal')) {
      return { text: '/relaunch needs a local terminal; this session has none.' }
    }

    let mode = parsed.mode

    if (mode === 'ask') {
      let answer: string

      try {
        answer = await $.ui.ask('Relaunch this session in a new tab?', {
          header: 'Relaunch',
          options: [...Object.keys(CHOICES), CANCEL],
        })
      } catch {
        return { text: USAGE }
      }

      const picked = CHOICES[answer]

      if (!picked) {
        return { text: 'Relaunch cancelled.' }
      }

      mode = picked
    }

    if (mode === 'compact') {
      $.clock.after(EXIT_DELAY_MS, () => void compactThenRelaunch($, parsed.note, startModel))

      return { text: 'Compacting, then relaunching in a new tab...' }
    }

    const stay = mode === 'stay'
    const launched = await launch($, stay, parsed.note, startModel)

    if (!launched.ok) {
      return { text: launched.text }
    }

    const opened = launched.opened

    if (stay) {
      return { text: `${opened}\nIt starts once you /exit here, however long that takes.` }
    }

    $.ui.toast('Relaunching in a new tab...')
    exitSoon($, opened)

    return { text: `${opened}\nExiting this session...` }
  })
    .catch(($, e, next) => (next.called ? next(e) : { text: `/relaunch failed: ${next.error.message}` }))

  // MCP-change nudge: after the call, a transcript line for the person
  // (`ui.log` is never sent to the model); the result goes back untouched.
  on('tool.call', { tool: ['Bash', 'PowerShell', 'Write', 'Edit'] }, async ($, e, next) => {
    const result = await next(e)

    if (!result.deny && !result.isError) {
      const change = mcpChange(e.tool, e)

      if (change) {
        $.ui.log(`MCP config changed (${change}); /relaunch to load it`)
      }
    }

    return result
  })
    .catch(($, e, next) => next(e))
}
