#if DEBUG && targetEnvironment(simulator)
import Foundation
import CryptoKit

private final class DiagnosticFixture:URLProtocol {
    static var scenario="ok", requests:[URLRequest]=[]
    static let token=String(repeating:"x",count:32), device=String(repeating:"d",count:32)
    override class func canInit(with request:URLRequest)->Bool {request.url?.host=="192.168.9.77"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.requests.append(request)
        precondition(request.url?.host=="192.168.9.77" && request.httpMethod=="GET")
        if Self.scenario=="offline"{client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost));return}
        let path=request.url!.path
        var status=200, value:[String:Any]=[:]
        if path=="/v2/health" {
            value=["app":"localshelf-reader","version":1,"serverKind":"nas","buildVersion":"0.1.18-dev","capabilities":["reader-v1","pair-v2","locate-v1"]+(Self.scenario=="legacy" ? []:["connection-diagnostics-v1"])]
            if Self.scenario=="redirect"{status=302}
            if Self.scenario=="wrongService"{value["app"]="not-a-reader"}
            if Self.scenario=="privateVersion"{value["buildVersion"]="PRIVATE_SYNTHETIC_TITLE"}
            if Self.scenario=="timeout"{client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
        }else if path=="/v2/identity" {
            let nonce=URLComponents(url:request.url!,resolvingAgainstBaseURL:true)!.queryItems![0].value!
            let mac=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(Self.device)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            value=["deviceId":Self.device,"proof":Self.scenario=="wrongIdentity" ? String(repeating:"0",count:64):mac]
        }else if path=="/v2/diagnostics" {
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            if Self.scenario=="authorization"{status=401}
            if Self.scenario=="busy"{status=503}
            value=["app":"localshelf-reader","schema":1,"libraries":["eh":["storage":"ready","index":"ready","catalog":Self.scenario=="unpublished" ? "not_published":"ready"]]]
        }else if path=="/v1/books" {
            value=["orderVerified":true,"total":1,"books":[["id":"1","title":"PRIVATE_SYNTHETIC_TITLE","rank":0]],"orderPolicy":"ehviewer-downloads-time-desc"]
            if Self.scenario=="badCatalog"{value["books"]=[["id":"../invalid","title":"PRIVATE_SYNTHETIC_TITLE","rank":0]]}
        }else{status=404}
        let data=Self.scenario=="oversize" ? Data(repeating:65,count:10000):try! JSONSerialization.data(withJSONObject:value)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Length":"\(data.count)"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

@MainActor enum DiagnosticChecks {
    static func run()async {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[DiagnosticFixture.self]
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.77:8089",token:DiagnosticFixture.token,deviceId:DiagnosticFixture.device)
        for name in ["ok","offline","unpaired","wrongIdentity","authorization","unpublished","manualDisabled","legacy","redirect","oversize","wrongService","privateVersion","timeout","busy","badCatalog"] {
            DiagnosticFixture.scenario=name;DiagnosticFixture.requests=[]
            let report=await ConnectionDiagnostics.run(address:code.address,code:name=="unpaired" ? nil:code,source:name=="manualDisabled" ? .manual:.eh,configuration:config)
            let succeeds=["ok","legacy","privateVersion"].contains(name)
            precondition((report.summary=="当前书库连接正常")==succeeds,"Unexpected diagnostic result: \(name)")
            for secret in [code.address,code.token,DiagnosticFixture.device,"PRIVATE_SYNTHETIC_TITLE"]{precondition(!report.text.contains(secret),"Diagnostic disclosure")}
            if ["wrongIdentity","unpaired","offline","redirect","oversize","wrongService","timeout"].contains(name){
                precondition(DiagnosticFixture.requests.allSatisfy{$0.value(forHTTPHeaderField:"Authorization")==nil})
            }
            precondition(DiagnosticFixture.requests.count<=4)
            print("PASS connection diagnostics \(name)")
        }
        DiagnosticFixture.requests=[]
        let invalid=await ConnectionDiagnostics.run(address:"https://public.example",code:code,source:.eh,configuration:config)
        precondition(invalid.summary=="地址格式需要调整" && DiagnosticFixture.requests.isEmpty)
        DiagnosticFixture.requests=[]
        let cancelled=Task{@MainActor in await ConnectionDiagnostics.run(address:code.address,code:code,source:.eh,configuration:config)}
        cancelled.cancel()
        let cancelledReport=await cancelled.value
        precondition(cancelledReport.summary=="诊断已取消" && DiagnosticFixture.requests.isEmpty)
        print("17 diagnostic scenarios passed")
    }
}
#endif
