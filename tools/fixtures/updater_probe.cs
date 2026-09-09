// Disposable native-process stand-in for Inno Setup and the restarted app.
// A .cmd file exercises cmd.exe quoting instead of the shipped .exe contract.
using System;
using System.IO;
using System.Reflection;

class UpdaterProbe
{
    static int Main(string[] args)
    {
        string executable = Assembly.GetExecutingAssembly().Location;
        string directory = Path.GetDirectoryName(executable);
        if (Path.GetFileName(executable) == "setup.exe")
        {
            File.WriteAllLines(Path.Combine(directory, "arguments.txt"), args);
            string exitFile = Path.Combine(directory, "setup-exit.txt");
            return File.Exists(exitFile) ? Int32.Parse(File.ReadAllText(exitFile)) : 0;
        }
        File.WriteAllText(Path.Combine(directory, "restarted.txt"), "restarted");
        return 0;
    }
}
