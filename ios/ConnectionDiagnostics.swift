import Foundation
import SwiftUI
import UIKit

struct ConnectionDiagnosticReport {
    struct Step:Identifiable {
        let id=UUID()
        let title:String, detail:String
        let passed:Bool
        let milliseconds:Int?
    }
    let date=Date()
    var steps:[Step]=[]
    var serverVersion="未取得"
    var summary="检查未完成"
    mutating func add(_ title:String,_ detail:String,_ passed:Bool=true,_ milliseconds:Int?=nil){
        steps.append(Step(title:title,detail:detail,passed:passed,milliseconds:milliseconds))
    }
    var text:String {
        let build=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let timestamp=ISO8601DateFormatter().string(from:date)
        return (["LocalShelf iOS \(build) · 连接诊断",timestamp,"NAS 版本：\(serverVersion)",summary]
            + steps.map{"\($0.passed ? "通过":"注意") · \($0.title)：\($0.detail)"+($0.milliseconds.map{"（\($0) ms）"} ?? "")}
            + ["仅只读检查；未测试图片完整性。已省略地址、账号、凭据、书名和图片。"])
            .joined(separator:"\n")
    }
}

enum ConnectionDiagnostics {
    struct Snapshot:Decodable {let app:String;let schema:Int;let libraries:[String:[String:String]]}
    @MainActor static func run(address:String,code:PairingCode?,source:ShelfSource,
                              configuration:URLSessionConfiguration = .ephemeral)async->ConnectionDiagnosticReport {
        var report=ConnectionDiagnosticReport()
        let base:URL
        do{base=try LibraryRules.address(address.trimmingCharacters(in:.whitespacesAndNewlines))}
        catch{report.add("地址检查","请填写完整的局域网阅读地址，包含 http:// 和阅读端口。",false);report.summary="地址格式需要调整";return report}
        report.add("地址检查","格式正确；不会探测管理或上传端口。")
        let http=LimitedHTTP(configuration:configuration,resourceTimeout:8)
        defer{http.close()}
        func get(_ path:String,token:String?=nil,limit:Int=8192)async throws->Data {
            try Task.checkCancellation()
            var request=URLRequest(url:URL(string:path,relativeTo:base)!)
            request.timeoutInterval=4
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let token{request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
            return try await http.data(request,limit:limit)
        }
        var phase="阅读服务"
        do {
            let started=Date()
            let raw=try await get("/v2/health")
            let elapsed=max(0,Int(Date().timeIntervalSince(started)*1000))
            report.add("阅读端口","已收到 HTTP 响应；不是依靠旧缓存判断。",true,elapsed)
            let service=try JSONDecoder().decode(ReaderService.self,from:raw)
            guard service.compatible else{throw ServerFailure.incompatible}
            if let object=try? JSONSerialization.jsonObject(with:raw) as? [String:Any],let version=object["buildVersion"] as? String,
               version.range(of:"^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(?:-dev)?$",options:.regularExpression) != nil {report.serverVersion=version}
            report.add("服务识别","已识别为兼容的 NAS 阅读服务。")
            guard let code,code.version==2 else{
                report.add("身份与权限","尚无可用的已保存配对；请先正常连接。诊断不会尝试密码。",false)
                report.summary="服务可达，尚未验证阅读权限";return report
            }
            phase="身份与权限"
            let nonce=(UUID().uuidString+UUID().uuidString).replacingOccurrences(of:"-",with:"").lowercased()
            let proof=try JSONDecoder().decode(IdentityProof.self,from:await get("/v2/identity?nonce="+nonce))
            guard PairingProof.verify(proof,code:code,nonce:nonce) else{
                report.add(phase,"无法确认是已配对的服务器，或保存的凭据已变化；未发送阅读凭据。",false)
                report.summary="服务器身份需要核对";return report
            }
            report.add("服务器身份","已确认是原配对服务器。")
            phase="书库就绪"
            if service.capabilities.contains("connection-diagnostics-v1") {
                let snapshot=try JSONDecoder().decode(Snapshot.self,from:await get("/v2/diagnostics",token:code.token))
                guard snapshot.app=="localshelf-reader",snapshot.schema==1 else{throw LibraryError.malformed}
                guard let checks=snapshot.libraries[source.rawValue] else{
                    report.add(phase,"当前书库未启用，请切换书库或检查 NAS 配置。",false)
                    report.summary="当前书库不可用";return report
                }
                for (key,title,detail) in [("storage","存储目录","目录不可读或未挂载"),("index","书库索引","索引不可读或暂时忙"),("catalog","已发布目录","目录尚未发布或暂不可读")] {
                    let ok=checks[key]=="ready"
                    report.add(title,ok ? "检查通过。":"\(detail)；诊断不会创建或修复数据。",ok)
                    if !ok{report.summary="NAS 书库暂未就绪";return report}
                }
            }else{report.add("详细健康检查","旧版 NAS 不支持，继续用实际目录请求检查。")}
            phase="目录读取"
            let data=try await get(source.path("/v1/books?offset=0&limit=50",target:.nas),token:code.token,limit:2*1024*1024)
            let list=try await Task.detached(priority:.utility){
                let value=try JSONDecoder().decode(BookList.self,from:data)
                try LibraryRules.validate(value)
                guard value.books.count<=50,source.accepts(value) else{throw LibraryError.malformed}
                return value
            }.value
            try Task.checkCancellation()
            report.add("读取权限与目录",list.total==0 ? "权限正常；当前书库为空。":"权限正常，已读取第一页目录；未下载封面或正文。")
            report.summary="当前书库连接正常"
        }catch{
            if Task.isCancelled{report.summary="诊断已取消";return report}
            report.add(phase,failureMessage(error,phase:phase),false)
            report.summary="检查未通过；未更改现有连接"
        }
        return report
    }
    static func failureMessage(_ error:Error,phase:String)->String {
        if let error=error as? URLError {
            switch error.code {
            case .timedOut:return "请求超时。检查同一局域网、服务端口和防火墙；仅凭此结果不能判定容器已停止。"
            case .notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost:return "阅读端口无法连接。可能是网络、服务或端口映射问题，不代表密码错误。"
            default:return "网络回复异常或被系统限制。请检查局域网权限；未更改配对。"
            }
        }
        if case ServerFailure.incompatible=error{return "该地址不是兼容的 NAS 阅读服务；请勿使用管理或上传端口。"}
        if case ServerFailure.status(let status)=error {
            if [401,403].contains(status){return "访问被拒绝，请核对保存的配对与权限；不会自动重试密码。"}
            if [429,502,503,504].contains(status){return "服务暂忙或书库未就绪，请稍后再试。"}
            if (300...399).contains(status){return "收到跳转，已停止；请核对阅读地址。"}
        }
        if let issue=error as? PageReadFailure {
            if issue == .authorization{return "访问被拒绝，请在连接设置核对配对与权限。"}
            if issue == .busy{return "服务暂忙或书库未就绪，请稍后再试。"}
        }
        return "回复格式不兼容或目录校验未通过；未修改缓存、书库或配对。"
    }
}

struct ConnectionDiagnosticView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library:Library
    @State private var report:ConnectionDiagnosticReport?
    @State private var attempt=0
    @State private var copied=false
    var body:some View {
        List {
            Section {
                if let report {
                    Text(report.summary).font(.headline)
                    ForEach(report.steps){step in
                        VStack(alignment:.leading,spacing:4){
                            Label(step.title,systemImage:step.passed ? "checkmark.circle":"exclamationmark.circle")
                                .foregroundStyle(step.passed ? ShelfTheme.accent:.orange)
                            Text(step.detail).font(.footnote).foregroundStyle(ShelfTheme.secondary)
                        }
                    }
                }else{ProgressView("正在只读检查…")}
            } footer:{Text("只检查当前 NAS，不扫描图片、不尝试密码、不自动重启。仅代表本次结果。")}
            .listRowBackground(ShelfTheme.surface)
            Section {
                Button(copied ? "已复制脱敏摘要":"复制脱敏诊断摘要"){
                    if let report{UIPasteboard.general.string=report.text;copied=true}
                }.disabled(report==nil).accessibilityIdentifier("copyConnectionDiagnostics")
                Button("重新检查"){report=nil;copied=false;attempt+=1}.disabled(report==nil)
            } footer:{Text("摘要不含地址、账号、凭据、书名或图片。")}.listRowBackground(ShelfTheme.surface)
        }.scrollContentBackground(.hidden).background(ShelfTheme.background)
        .navigationTitle("连接诊断").navigationBarTitleDisplayMode(.inline)
        .pageEdgeReturn{dismiss()}
        .task(id:attempt){let result=await library.diagnoseConnection();if !Task.isCancelled{report=result}}
    }
}
