param([string]$Directory, [string]$Recursive)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
public static class ALFileWatch {
  private static readonly object Gate = new object();
  private static void Emit(string path, string kind) {
    lock (Gate) {
      Console.WriteLine(kind + " " + Convert.ToBase64String(Encoding.UTF8.GetBytes(path)));
      Console.Out.Flush();
    }
  }
  public static void Run(string directory, bool recursive) {
    using (var watcher = new FileSystemWatcher(directory)) {
      watcher.IncludeSubdirectories = recursive;
      watcher.Created += (s, e) => Emit(e.FullPath, "created");
      watcher.Changed += (s, e) => Emit(e.FullPath, "modified");
      watcher.Deleted += (s, e) => Emit(e.FullPath, "removed");
      watcher.Renamed += (s, e) => { Emit(e.OldFullPath, "renamed"); Emit(e.FullPath, "renamed"); };
      watcher.Error += (s, e) => { Console.Error.WriteLine(e.GetException()); Environment.Exit(1); };
      lock (Gate) {
        watcher.EnableRaisingEvents = true;
        Console.WriteLine("ready");
        Console.Out.Flush();
      }
      Console.ReadLine();
    }
  }
}
"@
[ALFileWatch]::Run($Directory, [bool]::Parse($Recursive))
