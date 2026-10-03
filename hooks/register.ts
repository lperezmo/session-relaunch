/**
 * session-relaunch: `/relaunch` restarts this session in a new terminal tab
 * with `claude --resume <id>`, so MCP servers added since it started load.
 *
 * Steps: optionally compact, have relaunch.ps1 open a tab that waits for this
 * claude.exe to exit and then resumes the same session id with the same flags,
 * then exit this one. Resuming by id rather than `--continue` picks the right
 * session when several are open at once.
 *
 * Every `$.noun.verb(...)` is written literally here; the loader inventories
 * them statically.
 */

import type { On } from 'claude-code'

const COMMAND_NAME = 'relaunch'

const USAGE = [
  'Usage: /relaunch            reopen this session in a new tab and exit this one',
  '       /relaunch compact    compact first, then relaunch',
  '       /relaunch stay       open the new tab but leave this session running (it waits for you to /exit)',
].join('\n')

type LaunchResult =
  | { ok: true; pid: number; terminal: string; args: string[] }
  | { ok: false; error: string }

/** The helper's one JSON line, or a failure naming what it printed instead. */
function parseLaunch(stdout: string, stderr: string): LaunchResult {
  const line = stdout.trim().split(/\r?\n/).at(-1) ?? ''

  try {
    return JSON.parse(line) as LaunchResult
  } catch {
    return { ok: false, error: (stderr || stdout || 'relaunch.ps1 printed nothing').trim() }
  }
}

/**
 * Registers the command.
 *
 * @param on the engine's registrar
 */
export function register(on: On) {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND_NAME,
      description: 'Restart this session in a new tab (--resume) so new MCP servers load',
      argumentHint: '[compact|stay]',
    })

    return next(e)
  })

  on('command.run', { command: COMMAND_NAME }, async ($, e, next) => {
    const words = e.args.trim().toLowerCase().split(/\s+/).filter(Boolean)
    const unknown = words.filter(word => word !== 'compact' && word !== 'stay')

    if (unknown.length) {
      return { text: USAGE }
    }

    const surfaces = await $.session.surfaces()

    if (!surfaces.includes('terminal')) {
      return { text: '/relaunch needs a local terminal; this session has none.' }
    }

    if (words.includes('compact')) {
      const { skip } = await $.session.compact()

      if (skip) {
        return { text: 'Compaction was vetoed by a hook, so nothing was relaunched.' }
      }
    }

    const sessionId = await $.session.id()
    const cwd = await $.session.cwd()
    const script = `${$.plugin.root}\\hooks\\relaunch.ps1`

    const run = await $.process.run([
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
    ])

    const launch = parseLaunch(run.stdout, run.stderr)

    if (!launch.ok) {
      return { text: `/relaunch could not open the new tab: ${launch.error}` }
    }

    const opened = `Opened a new tab running: claude ${launch.args.join(' ')}`

    if (words.includes('stay')) {
      return { text: `${opened}\nIt starts once you /exit here (it gives up after 2 minutes).` }
    }

    $.ui.toast('Relaunching in a new tab...')

    try {
      await $.command.run({ command: 'exit' })
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error)

      return { text: `${opened}\nCould not exit this session automatically (${reason}); type /exit and the new tab takes over.` }
    }

    return { text: opened }
  })
    .catch(($, e, next) => (next.called ? next(e) : { text: `/relaunch failed: ${next.error.message}` }))
}
