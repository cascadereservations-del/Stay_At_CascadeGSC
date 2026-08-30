function quoteForWindowsCommand(value) {
  if (!/^[A-Za-z0-9_.,:=/@\\-]+$/.test(value)) throw new Error(`Unsafe Windows command argument: ${value}.`);
  return value;
}

export function prepareCommandSpawn(command, args, platform = process.platform, comspec = process.env.ComSpec) {
  const windowsCommandShim = platform === 'win32' && /\.cmd$/i.test(command);
  if (windowsCommandShim) {
    if (!comspec || !/cmd\.exe$/i.test(comspec)) throw new Error('Windows command processor is unavailable.');
    const commandLine = [command, ...args].map(quoteForWindowsCommand).join(' ');
    return {
      command: comspec,
      args: ['/d', '/s', '/c', commandLine],
      options: { shell: false },
    };
  }
  return {
    command,
    args,
    options: { shell: false },
  };
}
