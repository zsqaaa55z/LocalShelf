using LocalShelfUploader.Core;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
int checks=0;
void Check(bool ok,string name){if(!ok)throw new Exception(name);checks++;Console.WriteLine("PASS "+name);}
void Reject(Action action,string name){try{action();}catch(UploadException){checks++;Console.WriteLine("PASS "+name);return;}throw new Exception(name);}
Check(FolderRules.NaturalCompare("2.jpg","10.jpg")<0,"natural numeric order");
Check(FolderRules.NaturalCompare("第2页.jpg","第10页.jpg")<0,"Chinese numeric order");
Check(FolderRules.NaturalCompare("1.jpg","01.jpg")!=0,"deterministic leading-zero tie");
Check(FolderRules.NaturalCompare("999999999999999999999.jpg","1000000000000000000000.jpg")<0,"large numeric filenames");
Check(FolderRules.Address("192.168.50.10:8089").Port==8089,"explicit LAN port");
foreach(var address in new[]{"https://example.com/","http://8.8.8.8/","http://192.168.1.2/?token=bad","http://user:pass@192.168.1.2/","file:///tmp/","http://192.168.1.2/manual"})Reject(()=>FolderRules.Address(address),"reject unsafe address");
var root=Path.Combine(Path.GetTempPath(),"localshelf-uploader-check-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
try{
    File.WriteAllBytes(Path.Combine(root,"10.jpg"),[255,216,255,1]);File.WriteAllBytes(Path.Combine(root,"2.gif"),"GIF89a synthetic"u8.ToArray());File.WriteAllText(Path.Combine(root,"metadata.txt"),"ignored");
    var earlier=new DateTime(2026,1,1,12,0,0,DateTimeKind.Utc);
    File.SetLastWriteTimeUtc(Path.Combine(root,"10.jpg"),earlier);File.SetLastWriteTimeUtc(Path.Combine(root,"2.gif"),earlier.AddMinutes(1));
    var folder=FolderRules.Inspect(root);Check(folder.Files.Length==2,"ignore non-image metadata");Check(Path.GetFileName(folder.Files[0])=="10.jpg","Windows modification date is primary, oldest first");
    Check(folder.ModifiedUtcTicks[0]<folder.ModifiedUtcTicks[1],"original UTC file timestamps captured");
    File.SetLastWriteTimeUtc(Path.Combine(root,"2.gif"),earlier);folder=FolderRules.Inspect(root);
    Check(Path.GetFileName(folder.Files[0])=="2.gif","natural filename tie break only for equal modification dates");
    using var offline=new UploadClient(new Uri("http://127.0.0.1:8089/"));
    var manifest=await offline.Prepare(folder," Synthetic ",null,CancellationToken.None);Check(manifest.Title=="Synthetic"&&manifest.Files[0].Sha256.Length==64,"streamed SHA manifest");
    Check(manifest.Files.All(f=>f.ModifiedUtcTicks==earlier.Ticks),"manifest retains original Windows timestamps, not upload time");
    File.SetLastWriteTimeUtc(folder.Files[0],earlier.AddHours(1));
    try{await offline.Prepare(folder,"Changed date",null,CancellationToken.None);throw new Exception("changed timestamp accepted");}catch(UploadException){Check(true,"modification change stops stale page order");}
    File.SetLastWriteTimeUtc(folder.Files[0],earlier);
    using var canceled=new CancellationTokenSource();canceled.Cancel();try{await offline.Prepare(folder,"Cancel",null,canceled.Token);throw new Exception("cancellation");}catch(OperationCanceledException){Check(true,"cancel before file read");}
    Directory.CreateDirectory(Path.Combine(root,"nested"));Reject(()=>FolderRules.Inspect(root),"explicitly reject nested image folders");Directory.Delete(Path.Combine(root,"nested"));
    var handler=new FixtureTransport();using var simulated=new UploadClient(new Uri("http://127.0.0.1:8089"),handler);
    await simulated.Login("fixture-pass-123",CancellationToken.None);
    var staged=await simulated.Start(manifest,CancellationToken.None);
    Check(staged.Missing.SequenceEqual(new[]{1,2}),"upload receipt validated");
    var committed=await simulated.Upload(folder,manifest,staged,null,CancellationToken.None);
    Check(committed.Published && handler.Received.Count==2 && handler.PageOneRequests==2,"streaming upload, transient retry and atomic commit contract");
    var duplicate=await simulated.Start(manifest,CancellationToken.None);
    Check(duplicate.Published && duplicate.Missing.Length==0,"duplicate receipt skips pages");
    await simulated.Upload(folder,manifest,duplicate,null,CancellationToken.None);
    Check(handler.PageOneRequests==2,"no redundant body upload after commit");
    if(args.Length==1){
        using var live=new UploadClient(FolderRules.Address(args[0]));await live.Login("fixture-pass-123",CancellationToken.None);
        var state=await live.Start(manifest,CancellationToken.None);Check(!state.Published&&state.Missing.Length==2,"real protocol initial upload");
        var result=await live.Upload(folder,manifest,state,null,CancellationToken.None);Check(result.Published,"real protocol commit");
        var again=await live.Start(manifest,CancellationToken.None);Check(again.Published&&again.BookId==result.BookId,"real protocol duplicate safe");
    }
}finally{Directory.Delete(root,true);}
Console.WriteLine($"{checks} uploader checks passed");

sealed class FixtureTransport:HttpMessageHandler
{
    private BookManifest? manifest;
    private bool published;
    public HashSet<int> Received {get;}=[];
    public int PageOneRequests {get;private set;}
    private static readonly JsonSerializerOptions Json=new(JsonSerializerDefaults.Web);
    private HttpResponseMessage Reply(object value)=>new(HttpStatusCode.OK){Content=new StringContent(JsonSerializer.Serialize(value,Json))};
    private object State()=>new{uploadId=new string('c',64),bookId=published?"1":null,published,missing=Enumerable.Range(1,manifest!.Files.Length).Where(n=>!Received.Contains(n)).ToArray(),total=manifest.Files.Length,libraryId=new string('b',64)};
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
    {
        var path=request.RequestUri!.AbsolutePath;
        if(path=="/v2/manual-login")return Reply(new{version=1,token=new string('a',64),libraryId=new string('b',64)});
        if(request.Headers.Authorization?.ToString()!="Bearer "+new string('a',64))throw new Exception("wrong upload credential");
        if(path=="/manual/v1/uploads"){
            manifest=JsonSerializer.Deserialize<BookManifest>(await request.Content!.ReadAsByteArrayAsync(ct),Json)!;return Reply(State());
        }
        if(path.Contains("/files/")){
            int number=int.Parse(path.Split('/').Last());if(number==1&&++PageOneRequests==1)return new(HttpStatusCode.ServiceUnavailable){Content=new StringContent("{}")};
            var bytes=await request.Content!.ReadAsByteArrayAsync(ct);var page=manifest!.Files[number-1];
            if(bytes.Length!=page.Size||Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()!=page.Sha256)throw new Exception("changed upload bytes");
            Received.Add(number);return Reply(new{received=number});
        }
        if(path.EndsWith("/commit")){if(Received.Count!=manifest!.Files.Length)throw new Exception("premature publication");published=true;return Reply(State());}
        throw new Exception("unexpected route "+path);
    }
}
