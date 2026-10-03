/**
 * Spots a tool call that changed this machine's MCP configuration, so the
 * mod can tell the person a /relaunch would load it. Pure: it reads the tool
 * name and input and returns a short description, or null.
 */

/**
 * `claude mcp <verb>` with a verb that changes the configured servers, the
 * executable bare, as `claude.exe`/`claude.cmd`, or at the end of a path.
 */
const MCP_CLI_RE = /(?:^|[\s;&|(`'"\\/])claude(?:\.exe|\.cmd)?\s+mcp\s+(add-from-claude-desktop|add-json|add|remove)(?=\s|$|[;&|)`'"])/i

/** The basename of a Windows or POSIX path. */
function basename(path: string): string {
  return path.split(/[\\/]/).at(-1) ?? path
}

/**
 * Describes the MCP change a tool call made, or returns null.
 *
 * Covers `claude mcp add|add-json|add-from-claude-desktop|remove` in a Bash
 * or PowerShell command, and a Write or Edit of a `.mcp.json`.
 *
 * @param tool the tool's name (`e.tool`)
 * @param input the call's input (`e` itself works)
 */
export function mcpChange(tool: string, input: { command?: unknown; file_path?: unknown }): string | null {
  if (tool === 'Bash' || tool === 'PowerShell') {
    const command = typeof input.command === 'string' ? input.command : ''
    const match = MCP_CLI_RE.exec(command)

    return match ? `claude mcp ${match[1].toLowerCase()}` : null
  }

  if (tool === 'Write' || tool === 'Edit') {
    const path = typeof input.file_path === 'string' ? input.file_path : ''

    return basename(path).toLowerCase() === '.mcp.json' ? `${tool.toLowerCase()} of ${basename(path)}` : null
  }

  return null
}
