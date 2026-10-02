using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LocalShelfUploader.Core;

public record PageFile([property:JsonPropertyName("name")] string Name,
    [property:JsonPropertyName("size")] long Size, [property:JsonPropertyName("sha256")] string Sha256,
    [property:JsonPropertyName("modifiedUtcTicks")] long ModifiedUtcTicks);
public record BookManifest([property:JsonPropertyName("title")] string Title,
    [property:JsonPropertyName("files")] PageFile[] Files);
public record UploadState(string UploadId, string? BookId, bool Published, int[] Missing, int Total, string LibraryId);
public record PendingUpload(string UploadId,string Title,int Received,int Total){public string Display=>$"{Title}  ·  {Received}/{Total} 张已确认";}
public record UploadProgress(string Stage, int Page, int Total, long Bytes, long TotalBytes);
public record FolderSummary(string Path, string Title, string[] Files, long Size, long[] ModifiedUtcTicks);
public sealed class UploadException(string message) : Exception(message);

public static partial class FolderRules
{
    public const long MaxFile = 50 * 1024 * 1024, MaxBook = 20L * 1024 * 1024 * 1024;
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif" };
    [GeneratedRegex("([0-9]+)", RegexOptions.CultureInvariant)] private static partial Regex Digits();
    // Numeric comparison without integer overflow; deterministic ordinal ties.
    public static int NaturalCompare(string? a, string? b)
    {
        var x=Digits().Split(a ?? ""); var y=Digits().Split(b ?? "");
        for (int i=0; i<Math.Min(x.Length,y.Length); i++)
        {
            int c;
            if (i%2==1) {var p=x[i].TrimStart('0');var q=y[i].TrimStart('0');c=p.Length.CompareTo(q.Length);if(c==0)c=StringComparer.Ordinal.Compare(p,q);}
            else c=StringComparer.OrdinalIgnoreCase.Compare(x[i],y[i]);
            if(c!=0)return c;
        }
        int result=x.Length.CompareTo(y.Length);
        return result!=0 ? result : StringComparer.Ordinal.Compare(a,b);
    }
    public static FolderSummary Inspect(string path)
    {
        path=System.IO.Path.GetFullPath(path);
        if(path.Length>2048)throw new UploadException("文件夹路径过长，请放到更靠近磁盘根目录的位置后再上传。");
        if(!Directory.Exists(path) || (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new UploadException("请选择普通漫画文件夹，不支持快捷方式或链接目录。");
        if(Directory.EnumerateDirectories(path).Any())throw new UploadException("漫画内含子文件夹。首版请将每本漫画的图片放在同一层目录。");
        var images=Directory.EnumerateFiles(path).Where(p=>Extensions.Contains(System.IO.Path.GetExtension(p))).Take(20001).Select(p=>new FileInfo(p)).ToArray();
        if(images.Length is <1 or >20000)throw new UploadException("每本漫画需要 1–20000 张 JPG、PNG、GIF、WebP 或 AVIF 图片。");
        long total=0;
        foreach(var info in images){if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length<=0 || info.Length>MaxFile)throw new UploadException("存在链接、空文件或超过 50 MiB 的图片，未开始上传。");total+=info.Length;}
        Array.Sort(images,(a,b)=>{int date=a.LastWriteTimeUtc.CompareTo(b.LastWriteTimeUtc);return date!=0?date:NaturalCompare(a.Name,b.Name);});
        if(total>MaxBook)throw new UploadException("单本漫画超过 20 GiB，请拆分后上传。");
        return new(path,new DirectoryInfo(path).Name,images.Select(f=>f.FullName).ToArray(),total,images.Select(f=>f.LastWriteTimeUtc.Ticks).ToArray());
    }
    public static string[] Children(string parent) => Directory.EnumerateDirectories(parent)
        .Where(p=>(File.GetAttributes(p)&FileAttributes.ReparsePoint)==0).Take(501)
        .OrderBy(p=>System.IO.Path.GetFileName(p),Comparer<string>.Create(NaturalCompare)).ToArray();
    public static Uri Address(string value)
    {
        value=value.Trim();if(!value.Contains("://"))value="http://"+value;
        if(!Uri.TryCreate(value,UriKind.Absolute,out var uri) || uri.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(uri.UserInfo) || uri.AbsolutePath!="/" || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) || !IPAddress.TryParse(uri.Host,out var ip))throw new UploadException("请填写局域网 IPv4 阅读地址，例如 http://192.168.x.x:8089，不要填管理后台地址。");
        var b=ip.GetAddressBytes();
        if(b.Length!=4 || !(b[0]==10 || b[0]==192&&b[1]==168 || b[0]==172&&b[1]>=16&&b[1]<=31 || b[0]==127))throw new UploadException("此工具仅允许局域网 IPv4 地址，不允许公网上传。");
        return uri;
    }
}

public sealed class UploadClient : IDisposable
{
    private readonly HttpClient http;
    private string? token;
    private string? libraryId;
    private static readonly JsonSerializerOptions Json=new(JsonSerializerDefaults.Web);
    public UploadClient(Uri address) : this(address,new HttpClientHandler{AllowAutoRedirect=false,UseProxy=false}) { }
    // Injectable transport for isolated protocol checks; the app always uses
    // the public one-argument constructor above (no redirects, no proxy).
    internal UploadClient(Uri address,HttpMessageHandler handler)
    {
        // No proxy or redirect can forward a password/token to a third party.
        http=new(handler){BaseAddress=FolderRules.Address(address.ToString()),Timeout=TimeSpan.FromSeconds(120)};
    }
    public async Task Login(string password,CancellationToken ct)
    {
        if(Encoding.UTF8.GetByteCount(password) is <8 or >128)throw new UploadException("NAS 阅读密码长度应为 8–128 字节。");
        token=null;libraryId=null;
        using var message=new HttpRequestMessage(HttpMethod.Post,"/v2/manual-login"){Content=new StringContent(password,Encoding.UTF8,"text/plain")};
        using var response=await http.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,ct);
        var result=await ReadJson(response,ct);
        if(!result.TryGetProperty("version",out var version) || version.GetInt32()!=1)throw new UploadException("NAS 手动书库版本不兼容。");
        var key=result.GetProperty("token").GetString();var library=result.GetProperty("libraryId").GetString();
        if(key is null || library is null || !Regex.IsMatch(key,"\\A[a-f0-9]{64}\\z") || !Regex.IsMatch(library,"\\A[a-f0-9]{64}\\z"))throw new UploadException("NAS 返回的上传凭据无效。");
        token=key;libraryId=library;
    }
    public async Task<BookManifest> Prepare(FolderSummary folder,string title,IProgress<UploadProgress>? progress,CancellationToken ct)
    {
        title=title.Trim();
        if(title.Length==0 || Encoding.UTF8.GetByteCount(title)>4096 || title.Any(char.IsControl))throw new UploadException("漫画名称为空、过长或包含控制字符。");
        var pages=new List<PageFile>();long done=0;
        for(int i=0;i<folder.Files.Length;i++)
        {
            ct.ThrowIfCancellationRequested();var file=folder.Files[i];
            if(File.GetLastWriteTimeUtc(file).Ticks!=folder.ModifiedUtcTicks[i])throw new UploadException("图片修改日期已变化。请移出并重新添加文件夹，以免页序出错。");
            if((File.GetAttributes(file)&FileAttributes.ReparsePoint)!=0)throw new UploadException("图片变成了链接，请重新选择文件夹。");
            await using var input=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read,256*1024,FileOptions.Asynchronous|FileOptions.SequentialScan);
            if(input.Length<=0 || input.Length>FolderRules.MaxFile)throw new UploadException("图片大小已变化或超过限制，请重新选择。");
            var hash=Convert.ToHexString(await SHA256.HashDataAsync(input,ct)).ToLowerInvariant();
            if(File.GetLastWriteTimeUtc(file).Ticks!=folder.ModifiedUtcTicks[i])throw new UploadException("校验期间图片修改日期发生变化，请重新添加文件夹。");
            pages.Add(new(System.IO.Path.GetFileName(file),input.Length,hash,folder.ModifiedUtcTicks[i]));done+=input.Length;
            progress?.Report(new("核对本机图片",i+1,folder.Files.Length,done,folder.Size));
        }
        if(done>FolderRules.MaxBook)throw new UploadException("单本漫画超过 20 GiB。");
        return new(title,pages.ToArray());
    }
    public async Task<UploadState> Start(BookManifest manifest,CancellationToken ct)
    {
        var bytes=JsonSerializer.SerializeToUtf8Bytes(manifest,Json);
        if(bytes.Length>8*1024*1024)throw new UploadException("漫画文件清单过大。");
        return State(await Send("/manual/v1/uploads",()=>new ByteArrayContent(bytes),ct));
    }
    private UploadState State(JsonElement json)
    {
        var value=json.Deserialize<UploadState>(Json) ?? throw new UploadException("上传回执为空。");
        if(value.LibraryId!=libraryId || value.UploadId is null || !Regex.IsMatch(value.UploadId,"\\A[a-f0-9]{64}\\z") || value.Total is <1 or >20000 || value.Missing is null || value.Missing.Any(n=>n<1||n>value.Total) || value.Missing.Distinct().Count()!=value.Missing.Length)throw new UploadException("上传回执无效，已停止。");
        return value;
    }
    public async Task<UploadState> Upload(FolderSummary folder,BookManifest manifest,UploadState state,IProgress<UploadProgress>? progress,CancellationToken ct)
    {
        if(state.Total!=manifest.Files.Length || folder.Files.Length!=state.Total)throw new UploadException("文件清单发生变化，请重新选择。");
        if(state.Published){if(state.Missing.Length>0)throw new UploadException("该漫画已发布，但 NAS 文件缺失，需要管理员检查。");return state;}
        long total=manifest.Files.Sum(p=>p.Size),done=total-state.Missing.Sum(n=>manifest.Files[n-1].Size);
        int finished=state.Total-state.Missing.Length;
        foreach(int number in state.Missing)
        {
            ct.ThrowIfCancellationRequested();var page=manifest.Files[number-1];var path=folder.Files[number-1];
            long before=done;int beforePages=finished;
            await Send($"/manual/v1/uploads/{state.UploadId}/files/{number}",()=>{
                if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new UploadException("源图片变成了链接，已停止。");
                if(File.GetLastWriteTimeUtc(path).Ticks!=page.ModifiedUtcTicks)throw new UploadException("图片修改日期已变化，请重新添加文件夹核对顺序。");
                var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,256*1024,FileOptions.Asynchronous|FileOptions.SequentialScan);
                if(input.Length!=page.Size){input.Dispose();throw new UploadException("源图片已变化，请重新选择漫画。");}
                return new ProgressContent(input,sent=>progress?.Report(new("上传到手动书库",beforePages,state.Total,before+sent,total)));
            },ct);
            done+=page.Size;finished++;progress?.Report(new("已确认上传",finished,state.Total,done,total));
        }
        progress?.Report(new("发布整本漫画",state.Total,state.Total,total,total));
        var committed=State(await Send($"/manual/v1/uploads/{state.UploadId}/commit",()=>new ByteArrayContent([]),ct));
        if(!committed.Published || committed.Missing.Length!=0)throw new UploadException("NAS 尚未确认整本发布，请重新点击上传继续。");
        return committed;
    }
    public Task Discard(UploadState state,CancellationToken ct) => Send($"/manual/v1/uploads/{state.UploadId}/discard",()=>new ByteArrayContent([]),ct);
    public Task Discard(PendingUpload state,CancellationToken ct){if(!Regex.IsMatch(state.UploadId,"\\A[a-f0-9]{64}\\z"))throw new UploadException("无效任务。");return Send($"/manual/v1/uploads/{state.UploadId}/discard",()=>new ByteArrayContent([]),ct);}
    public async Task<PendingUpload[]> Pending(CancellationToken ct)
    {
        if(token is null)throw new UploadException("请先连接 NAS。");
        using var request=new HttpRequestMessage(HttpMethod.Get,"/manual/v1/uploads");request.Headers.Authorization=new("Bearer",token);
        using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
        var data=await ReadJson(response,ct);var items=data.GetProperty("uploads").Deserialize<PendingUpload[]>(Json) ?? [];
        if(items.Length>20 || items.Any(p=>p.Title is null || p.UploadId is null || !Regex.IsMatch(p.UploadId,"\\A[a-f0-9]{64}\\z")))throw new UploadException("任务列表无效。");
        return items;
    }
    private async Task<JsonElement> Send(string path,Func<HttpContent> content,CancellationToken ct)
    {
        if(token is null)throw new UploadException("请先连接 NAS。");
        for(int attempt=0;;attempt++)
        {
            try
            {
                using var message=new HttpRequestMessage(HttpMethod.Post,path){Content=content()};
                message.Headers.Authorization=new AuthenticationHeaderValue("Bearer",token);
                using var response=await http.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,ct);
                if((int)response.StatusCode is 502 or 503 or 504 && attempt<2){await Task.Delay(1000*(attempt+1),ct);continue;}
                return await ReadJson(response,ct);
            }
            catch(HttpRequestException) when(attempt<2){await Task.Delay(1000*(attempt+1),ct);}
            catch(TaskCanceledException) when(!ct.IsCancellationRequested && attempt<2){await Task.Delay(1000*(attempt+1),ct);}
        }
    }
    private static async Task<JsonElement> ReadJson(HttpResponseMessage response,CancellationToken ct)
    {
        const int limit=256*1024;
        if(response.Content.Headers.ContentLength>limit)throw new UploadException("NAS 回执过大。");
        await using var stream=await response.Content.ReadAsStreamAsync(ct);
        using var buffer=new MemoryStream();var chunk=new byte[8192];
        int read;while((read=await stream.ReadAsync(chunk,ct))>0){if(buffer.Length+read>limit)throw new UploadException("NAS 回执过大。");buffer.Write(chunk,0,read);}
        JsonElement value;
        try{using var json=JsonDocument.Parse(buffer.ToArray());value=json.RootElement.Clone();}
        catch(JsonException){throw new UploadException("这不是手动书库接口，请核对阅读服务地址和端口。");}
        if(response.StatusCode!=HttpStatusCode.OK)
        {
            string code=value.ValueKind==JsonValueKind.Object&&value.TryGetProperty("error",out var error) ? error.GetString() ?? "":"";
            throw new UploadException(code switch {
                "manual_library_disabled" or "route_not_found"=>"NAS 尚未启用手动上传，请先部署新服务。",
                "incorrect_password"=>"NAS 密码不正确。",
                "manual_auth_required"=>"上传凭据已失效，请重新连接。",
                "manual_disk_full"=>"NAS 空间不足，至少需要额外保留 1 GiB。",
                "upload_hash_mismatch"=>"图片校验不一致，源文件可能正在修改，请重试。",
                "upload_not_image"=>"有文件的实际格式与扩展名不一致，已停止，未发布这本漫画。",
                "too_many_pending_uploads"=>"未完成上传已达 20 本，请先续传或放弃已有任务。",
                "upload_pages_missing"=>"仍有图片未传完，请再次上传以续传。",
                _=>$"NAS 拒绝了本次操作（{(int)response.StatusCode}），进度保留；请核对版本、密码或稍后重试。"});
        }
        return value;
    }
    public void Dispose()=>http.Dispose();

    private sealed class ProgressContent(FileStream input,Action<long> changed):HttpContent
    {
        protected override bool TryComputeLength(out long length){length=input.Length;return true;}
        protected override Task SerializeToStreamAsync(Stream stream,TransportContext? context)=>Copy(stream,CancellationToken.None);
        protected override Task SerializeToStreamAsync(Stream stream,TransportContext? context,CancellationToken ct)=>Copy(stream,ct);
        private async Task Copy(Stream target,CancellationToken ct){var buffer=new byte[256*1024];int n;long total=0;var clock=System.Diagnostics.Stopwatch.StartNew();while((n=await input.ReadAsync(buffer,ct))>0){await target.WriteAsync(buffer.AsMemory(0,n),ct);total+=n;if(clock.ElapsedMilliseconds>=100){changed(total);clock.Restart();}}changed(total);}
        protected override void Dispose(bool disposing){if(disposing)input.Dispose();base.Dispose(disposing);}
    }
}
