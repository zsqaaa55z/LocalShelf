using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using LocalShelfUploader.Core;
using Microsoft.Win32;

namespace LocalShelfUploader;

public sealed class QueueBook(FolderSummary folder):INotifyPropertyChanged
{
    public FolderSummary Folder {get;}=folder;
    public string Title {get;set;}=folder.Title;
    public int Pages=>Folder.Files.Length;
    public string SizeText=>$"{Folder.Size/(1024d*1024):0.0} MiB";
    public bool Completed {get;set;}
    private string status="等待上传";
    public string Status {get=>status;set{status=value;PropertyChanged?.Invoke(this,new(nameof(Status)));}}
    public event PropertyChangedEventHandler? PropertyChanged;
}

public partial class MainWindow:Window
{
    private readonly ObservableCollection<QueueBook> books=[];
    private UploadClient? client;
    private CancellationTokenSource? operation;
    private bool busy;
    private string connectedAddress="";
    private static string Settings=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LocalShelfUploader","address.txt");
    public MainWindow(){InitializeComponent();Queue.ItemsSource=books;try{if(File.Exists(Settings))AddressBox.Text=FolderRules.Address(File.ReadAllText(Settings)).ToString();}catch{/* disposable address only */}}
    private void Busy(bool value){busy=value;PreviewButton.IsEnabled=AddButton.IsEnabled=BatchButton.IsEnabled=RemoveButton.IsEnabled=ClearButton.IsEnabled=ConnectButton.IsEnabled=AddressBox.IsEnabled=PasswordBox.IsEnabled=!value;Queue.IsReadOnly=value;PendingButton.IsEnabled=UploadButton.IsEnabled=!value&&client!=null;PauseButton.IsEnabled=value;}
    private async void Connect(object sender,RoutedEventArgs e)
    {
        if(busy)return;Busy(true);operation=new();client?.Dispose();client=null;connectedAddress="";
        try{var address=FolderRules.Address(AddressBox.Text);var next=new UploadClient(address);try{await next.Login(PasswordBox.Password,operation.Token);}catch{next.Dispose();throw;}client=next;connectedAddress=address.ToString();AddressBox.Text=connectedAddress;try{Directory.CreateDirectory(Path.GetDirectoryName(Settings)!);File.WriteAllText(Settings,connectedAddress);}catch{/* connection doesn't depend on preferences */}StatusText.Text="已连接独立手动书库。iPhone 首页顶部选择「手动上传」查看。";}
        catch(OperationCanceledException){StatusText.Text="连接已取消。";}
        catch(Exception error){StatusText.Text=SafeError(error);}
        finally{PasswordBox.Clear();operation.Dispose();operation=null;Busy(false);}
    }
    private void AddFolders(object sender,RoutedEventArgs e){var picker=new OpenFolderDialog{Title="选择漫画文件夹（可以多选）",Multiselect=true};if(picker.ShowDialog(this)==true)_=Add(picker.FolderNames);}
    private void AddParent(object sender,RoutedEventArgs e){var picker=new OpenFolderDialog{Title="选择包含多本漫画的总文件夹"};if(picker.ShowDialog(this)==true)_=AddFromParent(picker.FolderName);}
    private async Task AddFromParent(string path){try{var paths=await Task.Run(()=>FolderRules.Children(path));if(paths.Length>500)throw new UploadException("一次最多选择 500 本，请分批添加。");await Add(paths);}catch(Exception error){StatusText.Text=SafeError(error);}}
    private async Task Add(IEnumerable<string> paths)
    {
        if(busy)return;Busy(true);int added=0,failed=0;string? firstError=null;
        try{foreach(var path in paths.Take(501)){if(books.Count>=500)throw new UploadException("列表最多 500 本，请先完成这一批。");if(books.Any(b=>string.Equals(b.Folder.Path,Path.GetFullPath(path),StringComparison.OrdinalIgnoreCase)))continue;
            try{var folder=await Task.Run(()=>FolderRules.Inspect(path));if(books.Sum(b=>b.Pages)+folder.Files.Length>100000 || books.Sum(b=>b.Folder.Files.Sum(f=>(long)f.Length))+folder.Files.Sum(f=>(long)f.Length)>20000000)throw new UploadException("本批文件清单已达内存保护上限，请完成并清空当前列表后再添加。");books.Add(new(folder));added++;}catch(Exception error){failed++;firstError??=SafeError(error);}}
            StatusText.Text=$"已添加 {added} 本，共 {books.Count} 本。"+(failed>0?$" {failed} 个文件夹未添加：{firstError}":"可双击漫画名称修改标题。");}
        catch(Exception error){StatusText.Text=SafeError(error);}finally{Busy(false);}
    }
    private void OnDragOver(object sender,DragEventArgs e){e.Effects=!busy&&e.Data.GetDataPresent(DataFormats.FileDrop)?DragDropEffects.Copy:DragDropEffects.None;e.Handled=true;}
    private void OnDrop(object sender,DragEventArgs e){if(!busy&&e.Data.GetData(DataFormats.FileDrop) is string[] paths)_=Add(paths);}
    private void Remove(object sender,RoutedEventArgs e){foreach(var row in Queue.SelectedItems.Cast<QueueBook>().ToArray())books.Remove(row);}
    private void ClearCompleted(object sender,RoutedEventArgs e){foreach(var row in books.Where(b=>b.Completed).ToArray())books.Remove(row);}
    private void PreviewOrder(object sender,RoutedEventArgs e)
    {
        if(Queue.SelectedItem is not QueueBook row){StatusText.Text="请先在列表中选中一本漫画，再查看图片顺序。";return;}
        var columns=new GridView();columns.Columns.Add(new GridViewColumn{Header="页码",DisplayMemberBinding=new Binding("Page"),Width=60});columns.Columns.Add(new GridViewColumn{Header="原文件名",DisplayMemberBinding=new Binding("Name"),Width=310});columns.Columns.Add(new GridViewColumn{Header="Windows 修改日期（本地时间）",DisplayMemberBinding=new Binding("Date"),Width=270});
        var list=new ListView{View=columns,Margin=new Thickness(16),ItemsSource=row.Folder.Files.Select((file,i)=>new{Page=i+1,Name=Path.GetFileName(file),Date=new DateTime(row.Folder.ModifiedUtcTicks[i],DateTimeKind.Utc).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fffffff")})};
        var panel=new DockPanel();var note=new TextBlock{Text="修改日期从早到晚；相同精确时间按文件名自然排序。此处是添加时的顺序快照，上传前会复核日期。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(16)};DockPanel.SetDock(note,Dock.Top);panel.Children.Add(note);panel.Children.Add(list);
        new Window{Title="图片顺序 · "+row.Title,Owner=this,Width=740,Height=600,WindowStartupLocation=WindowStartupLocation.CenterOwner,Content=panel}.ShowDialog();
    }
    private void Pause(object sender,RoutedEventArgs e){operation?.Cancel();StatusText.Text="正在暂停，已确认上传的图片会保留；再次点击上传可以续传。";}
    private async void Upload(object sender,RoutedEventArgs e)
    {
        if(busy||client is null)return;
        try{if(FolderRules.Address(AddressBox.Text).ToString()!=connectedAddress)throw new UploadException("NAS 地址已变更，请重新连接后上传。");}catch(Exception error){StatusText.Text=SafeError(error);return;}
        Queue.CommitEdit();Queue.CommitEdit();
        Busy(true);operation=new();int completed=0;QueueBook? current=null;
        try{
            foreach(var row in books.Where(b=>!b.Completed).ToArray()){
                current=row;operation.Token.ThrowIfCancellationRequested();row.Status="核对本机图片…";
                var progress=new Progress<UploadProgress>(p=>{if(row.Completed||operation?.IsCancellationRequested!=false)return;row.Status=$"{p.Stage} {p.Page}/{p.Total}";Progress.Value=p.TotalBytes>0?Math.Clamp(100d*p.Bytes/p.TotalBytes,0,100):0;StatusText.Text=$"{row.Title} · {p.Stage} · {p.Bytes/(1024d*1024):0.0} / {p.TotalBytes/(1024d*1024):0.0} MiB";});
                var manifest=await client.Prepare(row.Folder,row.Title,progress,operation.Token);
                var state=await client.Start(manifest,operation.Token);
                await client.Upload(row.Folder,manifest,state,progress,operation.Token);
                row.Completed=true;row.Status=state.Published?"已存在 · 无需重传":"已完成 · 已入库";completed++;
            }
            Progress.Value=100;StatusText.Text=$"本次完成 {completed} 本。iPhone 首页顶部选择「手动上传」，点击刷新即可查看。";
        }
        catch(OperationCanceledException){if(current is not null&&!current.Completed)current.Status="已暂停 · 可续传";StatusText.Text="已暂停。已发布的漫画保留；未完成漫画下次继续。";}
        catch(Exception error){if(current is not null&&!current.Completed)current.Status="未完成 · 可重试";StatusText.Text=SafeError(error)+" 已完成漫画不受影响。";}
        finally{operation.Dispose();operation=null;Busy(false);}
    }
    private static string SafeError(Exception error)=>error is UploadException?error.Message:error is HttpRequestException?"连接中断，请检查 NAS 和局域网，再点击继续上传。":error is UnauthorizedAccessException?"无权读取所选文件，请检查文件权限。":error is IOException?"文件读取失败，可能正在移动或修改，请重新选择。":"操作未完成，请检查地址、文件内容或稍后重试。";
    private async void ManagePending(object sender,RoutedEventArgs e)
    {
        if(busy||client is null)return;Busy(true);operation=new();
        try{
            var items=await client.Pending(operation.Token);
            if(items.Length==0){StatusText.Text="NAS 没有未完成的上传。";return;}
            var list=new ListBox{ItemsSource=items,DisplayMemberPath="Display",Margin=new Thickness(16),MinHeight=180};
            var discard=new Button{Content="放弃所选未完成上传",Margin=new Thickness(16),HorizontalAlignment=HorizontalAlignment.Right};
            var panel=new DockPanel();var note=new TextBlock{Text="续传：关闭此窗口，重新添加相同文件夹并上传。\n放弃：仅删除未发布的上传暂存，不影响已入库漫画和 Eh 同步书库。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(16)};
            DockPanel.SetDock(note,Dock.Top);panel.Children.Add(note);DockPanel.SetDock(discard,Dock.Bottom);panel.Children.Add(discard);panel.Children.Add(list);
            var dialog=new Window{Title="未完成上传",Owner=this,Width=720,Height=380,WindowStartupLocation=WindowStartupLocation.CenterOwner,Content=panel};
            PendingUpload? selected=null;
            discard.Click+=(_,_)=>{if(list.SelectedItem is PendingUpload item&&MessageBox.Show(dialog,$"放弃「{item.Title}」的未完成上传？\n已传暂存将删除，下次需重新上传。","确认放弃",MessageBoxButton.YesNo,MessageBoxImage.Warning)==MessageBoxResult.Yes){selected=item;dialog.Close();}};
            dialog.ShowDialog();
            if(selected is not null){await client.Discard(selected,operation.Token);StatusText.Text="已移除所选未完成上传的 NAS 暂存；电脑原文件不变。";}
        }catch(OperationCanceledException){StatusText.Text="操作已取消。";}catch(Exception error){StatusText.Text=SafeError(error);}finally{operation.Dispose();operation=null;Busy(false);}
    }
    private void OnClosing(object? sender,CancelEventArgs e){if(busy){e.Cancel=true;operation?.Cancel();StatusText.Text="正在停止当前操作，停止后可关闭；重新选择相同文件夹可续传。";}else client?.Dispose();}
}
