import { describe, expect, test, tier } from 'claude-code/testing'

import { mcpChange } from '../hooks/mcp-change'
import { asPending, commandLine, isFresh, isModelFlag, isWindowsPath, parseArgs, parseLaunch } from '../hooks/parse'
import { USAGE } from '../hooks/register'

tier('user')

describe('parseArgs', () => {
  test('bare /relaunch asks', () => {
    expect(parseArgs('')).toEqual({ mode: 'ask', note: '' })
    expect(parseArgs('   ')).toEqual({ mode: 'ask', note: '' })
  })

  test('a keyword alone picks its mode', () => {
    expect(parseArgs('now')).toEqual({ mode: 'now', note: '' })
    expect(parseArgs('compact')).toEqual({ mode: 'compact', note: '' })
    expect(parseArgs(' STAY ')).toEqual({ mode: 'stay', note: '' })
  })

  test('everything after the keyword is the note, case kept', () => {
    expect(parseArgs('now  check the GitHub tools')).toEqual({ mode: 'now', note: 'check the GitHub tools' })
    expect(parseArgs('compact stay')).toEqual({ mode: 'compact', note: 'stay' })
  })

  test('text without a keyword is all note and still asks', () => {
    expect(parseArgs('try the new server')).toEqual({ mode: 'ask', note: 'try the new server' })
    expect(parseArgs('stya')).toEqual({ mode: 'ask', note: 'stya' })
  })

  test('help, ? and --help show usage', () => {
    expect(parseArgs('help').mode).toBe('help')
    expect(parseArgs('?').mode).toBe('help')
    expect(parseArgs('--help').mode).toBe('help')
  })
})

describe('parseLaunch', () => {
  test('the last JSON line wins', () => {
    const line = JSON.stringify({
      ok: true,
      pid: 42,
      terminal: 'windows-terminal',
      exe: 'C:\\bin\\claude.exe',
      args: ['--resume', 'abc'],
      title: 'claude relaunch',
    })

    expect(parseLaunch(`noise\r\n${line}\r\n`, '')).toEqual(JSON.parse(line))
  })

  test('a failure line passes through', () => {
    expect(parseLaunch('{"ok":false,"error":"no parent"}', '')).toEqual({ ok: false, error: 'no parent' })
  })

  test('anything else is a failure naming stderr, then stdout', () => {
    expect(parseLaunch('garbage', 'boom')).toEqual({ ok: false, error: 'boom' })
    expect(parseLaunch('garbage', '')).toEqual({ ok: false, error: 'garbage' })
    expect(parseLaunch('', '')).toEqual({ ok: false, error: 'the relaunch helper printed nothing' })
    expect(parseLaunch('{"pid":1}', '')).toEqual({ ok: false, error: '{"pid":1}' })
  })

  test('commandLine quotes parts with spaces', () => {
    expect(commandLine('C:\\Program Files\\claude.exe', ['--resume', 'abc', '--append-system-prompt', 'be brief'])).toBe(
      '"C:\\Program Files\\claude.exe" --resume abc --append-system-prompt "be brief"',
    )
  })
})

describe('isModelFlag', () => {
  test('ids and aliases pass', () => {
    expect(isModelFlag('claude-opus-5-5')).toBe(true)
    expect(isModelFlag('sonnet')).toBe(true)
    expect(isModelFlag('claude-opus-5-5[1m]')).toBe(true)
    expect(isModelFlag('us.anthropic.claude-sonnet-5-5-v1:0')).toBe(true)
  })

  test('display names and junk do not', () => {
    expect(isModelFlag('Opus 5.5')).toBe(false)
    expect(isModelFlag('Sonnet (1M context)')).toBe(false)
    expect(isModelFlag('')).toBe(false)
    expect(isModelFlag('--dangerously-skip-permissions')).toBe(false)
    expect(isModelFlag(undefined)).toBe(false)
  })
})

describe('pending record', () => {
  test('asPending narrows and fills defaults', () => {
    expect(asPending({ id: 'a', at: 5 })).toEqual({ id: 'a', at: 5, note: '', ttlMs: 600000 })
    expect(asPending({ id: 'a' })).toBeNull()
    expect(asPending('a')).toBeNull()
    expect(asPending(undefined)).toBeNull()
  })

  test('isFresh honours the time to live', () => {
    const record = { id: 'a', at: 1000, note: '', ttlMs: 600000 }

    expect(isFresh(record, 1000)).toBe(true)
    expect(isFresh(record, 601000)).toBe(true)
    expect(isFresh(record, 601001)).toBe(false)
    expect(isFresh(record, 999)).toBe(false)
  })
})

describe('mcpChange', () => {
  test('claude mcp verbs that change servers are caught', () => {
    expect(mcpChange('Bash', { command: 'claude mcp add github -- npx github-mcp' })).toBe('claude mcp add')
    expect(mcpChange('Bash', { command: 'cd /d/x && claude mcp add-json foo \'{"type":"http"}\'' })).toBe('claude mcp add-json')
    expect(mcpChange('PowerShell', { command: 'claude.exe mcp add-from-claude-desktop' })).toBe('claude mcp add-from-claude-desktop')
    expect(mcpChange('PowerShell', { command: 'claude mcp remove github -s user' })).toBe('claude mcp remove')
    expect(mcpChange('Bash', { command: 'C:\\bin\\claude.exe mcp add x -- y' })).toBe('claude mcp add')
  })

  test('read-only verbs and lookalikes are not', () => {
    expect(mcpChange('Bash', { command: 'claude mcp list' })).toBeNull()
    expect(mcpChange('Bash', { command: 'claude mcp get github' })).toBeNull()
    expect(mcpChange('Bash', { command: 'myclaude mcp add x' })).toBeNull()
    expect(mcpChange('Bash', { command: 'claude mcp addendum' })).toBeNull()
    expect(mcpChange('Bash', { command: 'echo done' })).toBeNull()
  })

  test('Write and Edit of a .mcp.json are caught, other files are not', () => {
    expect(mcpChange('Write', { file_path: 'D:\\Python\\proj\\.mcp.json' })).toBe('write of .mcp.json')
    expect(mcpChange('Edit', { file_path: '/home/x/.MCP.json' })).toBe('edit of .MCP.json')
    expect(mcpChange('Edit', { file_path: 'D:\\x\\mcp.json' })).toBeNull()
    expect(mcpChange('Write', { file_path: 'D:\\x\\.mcp.json.bak' })).toBeNull()
  })

  test('other tools are ignored', () => {
    expect(mcpChange('Read', { file_path: 'D:\\x\\.mcp.json' })).toBeNull()
    expect(mcpChange('Grep', { command: 'claude mcp add' })).toBeNull()
  })
})

describe('register', () => {
  test('/relaunch help answers with the usage', async ($, on) => {
    const { text } = await $.command.run({ command: 'relaunch', args: 'help' })

    expect(text).toBe(USAGE)
  })

  test('/relaunch refuses without a terminal surface', async ($, on) => {
    on('session.surfaces', () => ({ value: [] }))

    const { text } = await $.command.run({ command: 'relaunch', args: 'now' })

    expect(text).toContain('needs a local terminal')
  })

  test('bare /relaunch falls back to the usage when the dialog fails', async ($, on) => {
    on('session.surfaces', () => ({ value: ['terminal'] }))
    on('tool.call', { tool: 'AskUserQuestion' }, () => ({ deny: 'no dialog here' }))

    const { text } = await $.command.run({ command: 'relaunch', args: '' })

    expect(text).toBe(USAGE)
  })

  test('picking Cancel in the dialog relaunches nothing', async ($, on) => {
    on('session.surfaces', () => ({ value: ['terminal'] }))
    on('tool.call', { tool: 'AskUserQuestion' }, (_$, e) => ({
      result: { questions: e.questions, answers: { [e.questions[0].question]: 'Cancel' } },
    }))

    const { text } = await $.command.run({ command: 'relaunch', args: 'a note' })

    expect(text).toBe('Relaunch cancelled.')
  })

  test('claude mcp add tells the person and leaves the result alone', async ($, on) => {
    const logged: string[] = []
    const record = { stdout: 'Added', stderr: '', interrupted: false }

    on('tool.call', { tool: 'Bash' }, () => ({ result: record }))
    on('ui.log', (_$, e) => {
      logged.push(e.text)

      return { value: undefined }
    })

    const r = await $.tool.call({ tool: 'Bash', command: 'claude mcp add github -- npx github-mcp' })

    expect(r.result).toEqual(record)
    expect(logged).toEqual(['MCP config changed (claude mcp add); /relaunch to load it'])
  })

  test('a denied call or an unrelated one logs nothing', async ($, on) => {
    const logged: string[] = []

    on('tool.call', { tool: ['Bash', 'Write'] }, (_$, e) =>
      e.tool === 'Bash' ? { deny: 'blocked' } : { result: { type: 'create', filePath: 'x' } },
    )
    on('ui.log', (_$, e) => {
      logged.push(e.text)

      return { value: undefined }
    })

    await $.tool.call({ tool: 'Bash', command: 'claude mcp remove github' })
    await $.tool.call({ tool: 'Write', file_path: 'D:\\x\\notes.md', content: '' })

    expect(logged).toEqual([])
  })
})

describe('isWindowsPath', () => {
  test('drive letters and UNC shares are Windows', () => {
    expect(isWindowsPath('C:\\Users\\me\\.claude\\plugins\\session-relaunch')).toBe(true)
    expect(isWindowsPath('d:/Python/session-relaunch')).toBe(true)
    expect(isWindowsPath('\\\\server\\share\\plugin')).toBe(true)
  })

  test('POSIX paths are not', () => {
    expect(isWindowsPath('/home/me/.claude/plugins/session-relaunch')).toBe(false)
    expect(isWindowsPath('/Users/me/.claude/plugins/session-relaunch')).toBe(false)
  })
})
