#!/usr/bin/env python3
"""Exercise TUI project switches and soft restarts using global Pragtical (POSIX).

Uses a controlling PTY, SDL dummy drivers and isolated profiles. Launch paths,
runtime snapshots and terminal output are retained under /tmp by default.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import tempfile
import termios
import time


DRIVER = r'''
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local json = require "core.json"
config.plugins.ipc = false
config.plugins.workspace = false
config.plugins.autorestart = false
config.auto_fps, config.fps = false, 50
config.transitions = false
local generation_file = USERDIR .. "/generation"
local file = io.open(generation_file, "r")
local generation = file and tonumber(file:read("*a")) or 0
if file then file:close() end
generation = generation + 1
file = assert(io.open(generation_file, "w"))
file:write(generation); file:close()
local function snapshot()
  local docs, errors = {}, {}
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename then docs[#docs+1] = doc.abs_filename end
  end
  for _, entry in ipairs(core.log_items) do
    if entry.level == "ERROR" then errors[#errors+1] = entry.text end
  end
  local data = {generation=generation, restarted=RESTARTED,
    project=core.root_project().path, docs=docs, errors=errors,
    active=require("plugins.tui").active, renderer=core.window:get_renderer_info().backend}
  local output = assert(io.open(USERDIR .. "/state.tmp", "w"))
  output:write(json.encode(data)); output:close()
  os.rename(USERDIR .. "/state.tmp", USERDIR .. "/state.json")
end
core.add_thread(function()
  coroutine.yield(.15)
  snapshot()
  while true do
    local input = io.open(USERDIR .. "/request.json", "r")
    if input then
      local request = json.decode(input:read("*a")); input:close()
      os.remove(USERDIR .. "/request.json")
      if request.action == "change" then
        assert(command.perform("core:change-project-folder-commandview"))
        core.command_view:set_text(request.path)
        core.command_view:submit()
      elseif request.action == "restart" then
        core.root_view:close_all_docviews()
        command.perform("core:restart")
      elseif request.action == "quit" then
        core.quit(true)
      end
    end
    coroutine.yield(.02)
  end
end)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=shutil.which('pragtical'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or Path(tempfile.mkdtemp(prefix='pragtical-tui-restart-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = []

    def check(name, passed):
        checks.append({'name':name, 'passed':bool(passed)})
        print('PASS' if passed else 'FAIL', name, flush=True)

    cases = ('absolute-project', 'relative-project', 'absolute-files', 'relative-files', 'no-path')
    for name in cases:
        directory = output/name
        project_a, project_b = directory/'project a', directory/'project b'
        project_a.mkdir(parents=True)
        project_b.mkdir()
        launch_file = project_a/'launch.lua'
        launch_file.write_text('local launch = true\n')
        profile = directory/'profile'
        (profile/'plugins').mkdir(parents=True)
        (profile/'plugins/tui').symlink_to(Path(__file__).resolve().parents[1], target_is_directory=True)
        (profile/'init.lua').write_text(DRIVER)
        paths = [] if name == 'no-path' else [str(project_a) if name.startswith('absolute') else project_a.name]
        if name.endswith('files'):
            paths.append(str(launch_file) if name.startswith('absolute') else str(launch_file.relative_to(directory)))
        cwd = project_a if name == 'no-path' else directory
        argv = [str(args.binary), 'tui', *paths]
        (directory/'launch.json').write_text(json.dumps({'argv':argv, 'cwd':str(cwd)}, indent=2))
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            os.environ.update(PRAGTICAL_USERDIR=str(profile), SDL_VIDEO_DRIVER='dummy',
                SDL_AUDIO_DRIVER='dummy', PRAGTICAL_RENDERER='surface', TERM='xterm-256color', COLORTERM='truecolor')
            os.execv(str(args.binary), argv)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        transcript = bytearray()
        exited = False

        def drain(timeout):
            if select.select([fd], [], [], timeout)[0]:
                try: transcript.extend(os.read(fd, 65536))
                except OSError: pass

        def state(generation):
            nonlocal exited
            deadline = time.monotonic()+10
            while time.monotonic() < deadline:
                drain(.02)
                path = profile/'state.json'
                if path.exists():
                    data = json.loads(path.read_text())
                    if data['generation'] >= generation: return data
                if os.waitpid(pid, os.WNOHANG)[0]:
                    exited = True
                    raise RuntimeError('Editor exited; see '+str(directory/'terminal.log'))
            raise RuntimeError('Restart timed out; see '+str(directory))

        def request(action, path=None):
            data = {'action':action}
            if path is not None: data['path'] = str(path)
            (profile/'request.tmp').write_text(json.dumps(data))
            (profile/'request.tmp').replace(profile/'request.json')

        try:
            initial = state(1)
            check(name+' opens its initial project', initial['project'] == str(project_a))
            check(name+' opens only requested initial files', (initial['docs'] or []) == ([str(launch_file)] if name.endswith('files') else []))
            failed_switch = False
            for generation, destination in enumerate((project_b, project_a), 2):
                request('change', destination)
                data = state(generation)
                (directory/f'change-{generation}.json').write_text(json.dumps(data, indent=2))
                check(name+f' switch {generation-1} selects the new project', data['project'] == str(destination))
                check(name+f' switch {generation-1} keeps terminal mode', data['active'] and data['renderer'] == 'terminal' and data['restarted'])
                check(name+f' switch {generation-1} does not replay launch paths', not data['docs'] and not data['errors'])
                if data['docs'] or data['errors']:
                    failed_switch = True
                    break
            if not failed_switch:
                request('restart')
                data = state(4)
                (directory/'restart.json').write_text(json.dumps(data, indent=2))
                check(name+' plain restart keeps its project and terminal mode',
                    data['project'] == str(project_a) and data['active'] and data['renderer'] == 'terminal')
                check(name+' plain restart does not reopen closed launch files', not data['docs'] and not data['errors'])
            request('quit')
            deadline = time.monotonic()+5
            while time.monotonic() < deadline:
                drain(.02)
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    exited = True
                    check(name+' exits cleanly', os.waitstatus_to_exitcode(status) == 0)
                    break
            else: raise RuntimeError('Editor failed to quit')
        finally:
            if not exited:
                os.killpg(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
            os.close(fd)
            (directory/'terminal.log').write_bytes(transcript)
            (output/'checks.json').write_text(json.dumps(checks, indent=2))
    print('Restart checks:', output)
    if any(not item['passed'] for item in checks): raise SystemExit(1)


if __name__ == '__main__':
    main()
