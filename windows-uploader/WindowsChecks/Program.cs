using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LocalShelfUploader;
using LocalShelfUploader.Core;

internal static class Program
{
    // Offscreen render of this app only. No browser, NAS, credentials or input
    // automation. Runs in an isolated Windows temp directory over SSH.
    [STAThread] private static int Main(string[] args)
    {
        if(args.Length!=1)return 2;
        try{
            var app=new App();app.InitializeComponent();
            var window=new MainWindow();
            ((TextBox)window.FindName("AddressBox")).Text="http://192.168.1.2:8089";
            ((PasswordBox)window.FindName("PasswordBox")).Clear();
            ((TextBlock)window.FindName("StatusText")).Text="界面验证 · 合成漫画 · 不连接 NAS";
            var rows=new[]{new QueueBook(new FolderSummary("C:\\Synthetic\\Book 1","[示例作者] 测试漫画 1",["1.jpg","2.gif"],1048576,[639000000000000000,639000000001000000])),new QueueBook(new FolderSummary("C:\\Synthetic\\Book 2","[Demo Artist] Example Book 2",["10.jpg","2.jpg"],2097152,[639000000000000000,639000000001000000]))};
            ((DataGrid)window.FindName("Queue")).ItemsSource=rows;
            if(((Button)window.FindName("UploadButton")).IsEnabled)throw new Exception("Upload enabled without login");
            // WPF star-sized DataGrid columns require a presentation source and
            // dispatcher layout. Keep this QA window outside the visible desktop.
            window.WindowStartupLocation=WindowStartupLocation.Manual;
            window.Left=-30000;window.Top=-30000;window.ShowActivated=false;window.ShowInTaskbar=false;
            window.Show();window.Dispatcher.Invoke(()=>{},DispatcherPriority.ApplicationIdle);
            var root=(Grid)window.Content;root.Background=window.Background;root.UpdateLayout();
            if(((DataGrid)window.FindName("Queue")).Columns[0].ActualWidth<250)throw new Exception("Manga title column collapsed");
            int width=(int)Math.Ceiling(root.ActualWidth+root.Margin.Left+root.Margin.Right);
            int height=(int)Math.Ceiling(root.ActualHeight+root.Margin.Top+root.Margin.Bottom);
            var background=new DrawingVisual();using(var drawing=background.RenderOpen())drawing.DrawRectangle(window.Background,null,new Rect(0,0,width,height));
            var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(background);bitmap.Render(root);
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using(var file=File.Create(args[0]))encoder.Save(file);
            window.Close();app.Shutdown();Console.WriteLine("PASS Windows WPF construction, layout, disabled pre-login upload and offscreen rendering");return 0;
        }catch(Exception error){Console.Error.WriteLine(error);return 1;}
    }
}
