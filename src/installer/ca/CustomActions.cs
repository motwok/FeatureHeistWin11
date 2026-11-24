using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using WixToolset.Dtf.WindowsInstaller;

namespace FeatureHeist.Ca
{
    public static class CustomActions
    {
        [DllImport("user32.dll")]
        static extern IntPtr GetForegroundWindow();

        sealed class Owner : IWin32Window
        {
            public Owner(IntPtr h) { Handle = h; }
            public IntPtr Handle { get; }
        }

        // SourceDlg "Browse" for ISO: file dialog, result in FH_ISO_NEW (empty when cancelled)
        [CustomAction]
        public static ActionResult BrowseIso(Session session)
        {
            var current = session["ISO"];
            var owner = new Owner(GetForegroundWindow());
            string picked = null;
            var t = new Thread(() =>
            {
                using (var d = new OpenFileDialog())
                {
                    d.Filter = "Windows Server (*.iso;*.wim;*.esd)|*.iso;*.wim;*.esd|*.*|*.*";
                    d.CheckFileExists = true;
                    try
                    {
                        var dir = File.Exists(current) ? Path.GetDirectoryName(current) : current;
                        if (!string.IsNullOrWhiteSpace(dir) && Directory.Exists(dir)) d.InitialDirectory = dir;
                    }
                    catch (ArgumentException) { }
                    if (d.ShowDialog(owner) == DialogResult.OK) picked = d.FileName;
                }
            });
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
            t.Join();
            session["FH_ISO_NEW"] = picked ?? string.Empty;
            return ActionResult.Success;
        }
    }
}
