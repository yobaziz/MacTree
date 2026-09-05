using System.IO;
namespace MacTree.Windows;
internal static class ScannerChecks
{
    public static void Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "MacTree-check-" + Guid.NewGuid());
        Directory.CreateDirectory(Path.Combine(root, "nested", "empty"));
        try
        {
            File.WriteAllBytes(Path.Combine(root, "one.bin"), new byte[1024]);
            File.WriteAllBytes(Path.Combine(root, "nested", "two.bin"), new byte[3072]);
            var scanner = new DirectoryScanner();
            var result = scanner.Scan(root, CancellationToken.None);
            Require(result.Root.Bytes == 4096 && result.Root.Files == 2, "Nested totals");
            Require(result.Root.Children[0].Name == "nested", "Largest folder first");
            Require(result.Root.Children[0].Children.Single(x => x.Name == "empty").Bytes == 0, "Empty directory");
            using var cancel = new CancellationTokenSource(); cancel.Cancel();
            bool cancelled = false;
            try { scanner.Scan(root, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Require(cancelled, "Cancellation");
            bool failed = false;
            try { scanner.Scan(Path.Combine(root, "missing"), CancellationToken.None); } catch (DirectoryNotFoundException) { failed = true; }
            Require(failed, "Missing root must fail");
            // A junction back to the scan root must not cause recursion or duplicate totals.
            var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe")
            { Arguments = $"/c mklink /J \"{Path.Combine(root, "loop")}\" \"{root}\"", CreateNoWindow = true, UseShellExecute = false });
            process!.WaitForExit(); Require(process.ExitCode == 0, "Junction fixture");
            try
            {
                result = scanner.Scan(root, CancellationToken.None);
                Require(result.Root.Bytes == 4096 && result.Skipped == 1 && result.Root.Incomplete, "Skip junction loop");
            }
            finally { Directory.Delete(Path.Combine(root, "loop")); }
        }
        finally { Directory.Delete(root, true); }
    }
    private static void Require(bool ok, string name) { if (!ok) throw new Exception(name); }
}
