import SwiftUI
import UIKit
import ImageIO
import CryptoKit

#if DEBUG && targetEnvironment(simulator)
final class NASFixture:URLProtocol {
    static let lock=NSLock()
    static var ready=false,pinCalls=0
    static var passwordMode=false,passwordCalls=0,passwordStatus=200
    static var thumbnailMode=false,coverQueries:[String]=[]
    static var bodyMode=false,bodyVersion:UInt8=1,bodyRequests=0,manifestRequests=0,bodyCorrupt=false
    static var conditionalMode=false,manifestFault="",manifestBodies=0,manifestNotModified=0,manifestConditionals=0
    static let token=String(repeating:"N",count:32)
    static func publish(){lock.lock();ready=true;lock.unlock()}
    static func unpublish(){lock.lock();ready=false;lock.unlock()}
    override class func canInit(with request:URLRequest)->Bool{request.url?.host?.hasPrefix("192.168.9.")==true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let url=request.url!,nas=url.host=="192.168.9.2",wrong=url.host=="192.168.9.3"
        let id=String(repeating:nas ? "b":"a",count:32),library=String(repeating:nas ? "d":"c",count:64)
        var status=200,body:Data,headers:[String:String]=[:]
        if url.path=="/v2/health" {
            Self.lock.lock();let passwordMode=Self.passwordMode,thumbnailMode=Self.thumbnailMode;Self.lock.unlock()
            body=try! JSONSerialization.data(withJSONObject:["app":wrong ? "localshelf-sync":"localshelf-reader","version":1,"serverKind":"nas","capabilities":["reader-v1","pair-v2","locate-v1"]+(passwordMode ? ["password-pair-v1"]:[])+(thumbnailMode ? ["cover-thumbnail-v1"]:[])+(Self.bodyMode ? ["page-manifest-v1"]:[])+(Self.conditionalMode ? ["conditional-manifest-v1"]:[])])
        }else if url.path=="/v2/password-pair" {
            Self.lock.lock();Self.passwordCalls+=1;status=Self.passwordStatus;Self.lock.unlock()
            precondition(nas && request.httpMethod=="POST" && request.value(forHTTPHeaderField:"Authorization")==nil)
            var sent=request.httpBody ?? Data()
            if let stream=request.httpBodyStream{stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:129);let count=stream.read(&buffer,maxLength:buffer.count);if count>0{sent=Data(buffer.prefix(count))}}
            precondition(sent==Data("Synthetic-pass-42".utf8))
            body=status==200 ? try! JSONEncoder().encode(PairingCode(app:"localshelf",version:2,address:url.absoluteString,token:Self.token,deviceId:id)):Data()
        }else if url.path=="/v2/pair" {
            Self.lock.lock();Self.pinCalls+=1;Self.lock.unlock()
            body=try! JSONEncoder().encode(PairingCode(app:"localshelf",version:2,address:url.absoluteString,token:Self.token,deviceId:id))
        }else if url.path=="/v2/identity" {
            precondition(request.value(forHTTPHeaderField:"Authorization")==nil)
            let nonce=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(id)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":id,"proof":proof])
        }else{
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            Self.lock.lock();let ready=Self.ready;Self.lock.unlock()
            if nas && !ready{status=503;body=Data()}
            else if Self.bodyMode && (url.path.hasSuffix("/manifest") || url.path.contains("/pages/")) {
                let original=Data(repeating:Self.bodyVersion,count:1024*1024),sha=SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined()
                if url.path.hasSuffix("/manifest"){
                    Self.manifestRequests+=1
                    let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
                    body=try! encoder.encode(Pages(pages:[Page(number:1,sha256:sha,size:original.count)],id:"1",libraryId:library,contentRevision:sha))
                    if request.value(forHTTPHeaderField:"If-None-Match") != nil{Self.manifestConditionals+=1}
                    if Self.conditionalMode {
                        let tag="\""+SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()+"\""
                        headers["ETag"]=tag
                        if request.value(forHTTPHeaderField:"If-None-Match")==tag || Self.manifestFault=="unsolicited304" {status=304;body=Data()}
                        switch Self.manifestFault {
                        case "wrongTag":headers["ETag"]="\""+String(repeating:"f",count:64)+"\""
                        case "missingTag":headers.removeValue(forKey:"ETag")
                        case "badJSON":status=200;body=Data("invalid".utf8);headers["ETag"]="\""+SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()+"\""
                        case "401","409","503":status=Int(Self.manifestFault)!;body=Data()
                        default:break
                        }
                    }
                    if status==304{Self.manifestNotModified+=1}else if status==200{Self.manifestBodies+=1}
                }else{
                    Self.bodyRequests+=1;body=Self.bodyCorrupt ? Data(repeating:99,count:original.count):original;headers["ETag"]="\""+sha+"\""
                }
            }
            else if url.path.hasSuffix("/cover"){
                Self.lock.lock();Self.coverQueries.append(url.query ?? "");Self.lock.unlock()
                let tag="\""+String(repeating:"a",count:64)+"\"";headers["ETag"]=tag
                status=request.value(forHTTPHeaderField:"If-None-Match")==tag ? 304:200
                body=status==304 ? Data():Data("Synthetic thumbnail".utf8)
            }
            else if url.path.hasSuffix("/position"){
                body=try! JSONSerialization.data(withJSONObject:["id":"2","offset":1,"catalogRevision":String(repeating:"e",count:64),"libraryId":library])
            }else if url.path=="/v1/books" {
                let offset=Int(URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="offset"}!.value!)!
                let books=offset==0 ? [Book(id:"1",title:"Synthetic One",rank:0),Book(id:"2",title:"Synthetic Two",rank:1)]:[]
                body=try! JSONEncoder().encode(BookList(orderVerified:true,total:2,books:books,catalogRevision:String(repeating:"e",count:64),libraryId:library))
            }else{status=404;body=Data()}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
enum NASThumbnailChecks {
    @MainActor static func run()async {
        let defaults=UserDefaults.standard,selected=UserDefaults.standard.object(forKey:"server.selected"),hidden=UserDefaults.standard.object(forKey:"shelf.hideCovers")
        defer{defaults.set(selected,forKey:"server.selected");defaults.set(hidden,forKey:"shelf.hideCovers")}
        defaults.set("nas",forKey:"server.selected");defaults.set(false,forKey:"shelf.hideCovers")
        NASFixture.ready=true;NASFixture.thumbnailMode=true
        var saved:PairingCode?
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
        let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{saved},savePair:{saved=$0},removePair:{saved=nil})
        client.setForeground(false);client.address="http://192.168.9.2:8089";await client.connect(pin:"001234")
        precondition(client.base != nil)
        do{
            let route="/v1/books/1/cover"
            let first=try await client.coverResponse(route,etag:nil,pixels:320)
            precondition(first.status==200 && NASFixture.coverQueries.last=="width=320" && first.thumbnailPixels==320)
            let cached=try await client.coverResponse(route,etag:first.etag,pixels:320)
            precondition(cached.status==304 && cached.data.isEmpty)
            _=try await client.coverResponse(route,etag:nil,pixels:640)
            precondition(NASFixture.coverQueries.last=="width=640")
            print("PASS authenticated thumbnail width selection and conditional 304")
            NASFixture.thumbnailMode=false;await client.reconnect()
            let old=try await client.coverResponse(route,etag:nil,pixels:640)
            precondition(NASFixture.coverQueries.last=="" && old.thumbnailPixels==nil)
            print("PASS old NAS does not receive unsupported thumbnail parameters")
            await client.selectServer(.android);client.address="http://192.168.9.1:8088";await client.connect(pin:"001234")
            let android=try await client.coverResponse(route,etag:nil,pixels:480)
            precondition(NASFixture.coverQueries.last=="" && android.thumbnailPixels==nil)
            print("PASS Android keeps original cover protocol")
            client.coversHidden=true
            do{_=try await client.coverResponse(route,etag:nil);preconditionFailure("hidden cover loaded")}catch is CancellationError{}
            print("PASS cover privacy switch blocks new derivative requests")
        }catch{preconditionFailure("thumbnail protocol regression: \(error)")}
        client.setForeground(false)
        print("5 thumbnail wire contract checks passed")
    }
}
enum NASChecks {
    @MainActor static func run()async {
        let defaults=UserDefaults.standard
        func owned(_ key:String)->Bool{key.hasPrefix("reading.") || key.hasPrefix("page.") || key=="server.selected"}
        let before=defaults.dictionaryRepresentation().filter{owned($0.key)}
        defer{
            for key in defaults.dictionaryRepresentation().keys where owned(key){defaults.removeObject(forKey:key)}
            for (key,value) in before{defaults.set(value,forKey:key)}
        }
        defaults.set("android",forKey:"server.selected")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("reading."){defaults.removeObject(forKey:key)}
        var credentials:[ServerTarget:PairingCode]=[:]
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
        let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{credentials[ServerTarget.selected]},savePair:{credentials[ServerTarget.selected]=$0},removePair:{credentials[ServerTarget.selected]=nil},lookup:{_ in preconditionFailure("NAS must not use Android discovery")})
        client.setForeground(false)
        client.address="http://192.168.9.1:8088";await client.connect(pin:"001234")
        precondition(client.base != nil && credentials[.android] != nil);print("PASS Android profile retained")
        let android=client.recentScope!
        ReadingProgress.save(9,scope:android,id:"1");ReadingProgress.save(13,scope:android,id:"2");ReadingProgress.save(11,scope:android,id:"999")
        client.rememberReading(book:Book(id:"2",title:"Synthetic Two",rank:1),pages:[Page(number:13)],index:0,scope:android)
        await client.selectServer(.nas);client.address="http://192.168.9.3:8443"
        let attempts=NASFixture.pinCalls;await client.connect(pin:"001234")
        precondition(NASFixture.pinCalls==attempts && credentials[.nas]==nil && client.error.contains("阅读服务"));print("PASS upload endpoint rejected before PIN exchange")
        client.address="http://192.168.9.2:8089";await client.connect(pin:"001234")
        precondition(credentials[.nas] != nil && credentials[.android] != nil && client.base==nil && client.error.contains("尚未发布"));print("PASS pairing survives unpublished library and preserves Android credential")
        NASFixture.publish();await client.reconnect()
        precondition(client.base != nil && client.total==2);print("PASS published NAS reconnects without another PIN")
        let nas=client.recentScope!;ReadingProgress.save(5,scope:nas,id:"1")
        precondition(ReadingProgress.page(scope:nas,id:"2")==0 && ReadingProgress.page(scope:android,id:"2")==13);print("PASS NAS connection never copies Android progress")
        client.rememberReading(book:Book(id:"2",title:"Synthetic Two",rank:1),pages:[Page(number:7)],index:0,scope:nas)
        precondition(client.recentReading?.pageNumber==7 && ReadingProgress.page(scope:android,id:"2")==13);print("PASS NAS records its own progress without migration")
        let position=await client.locateRecentBook();precondition(position==1);print("PASS NAS position endpoint locates recent book")
        await client.selectServer(.android);await client.reconnect()
        precondition(client.recentScope==android && client.recentReading?.pageNumber==13);print("PASS manual Android fallback restores source recent reading")
        client.forget();precondition(credentials[.nas] != nil && ReadingProgress.page(scope:android,id:"2")==13);print("PASS unpair only removes selected credential, not reading records")
        client.setForeground(false)
        let reset=client.resetReadingProgress()
        precondition(reset>0 && ReadingProgress.page(scope:android,id:"2")==0 && ReadingProgress.page(scope:nas,id:"2")==0 && RecentReading.load(scope:android)==nil && RecentReading.load(scope:nas)==nil);print("PASS reset clears both source positions and recent records")
        precondition(credentials[.nas] != nil && client.recentReading==nil);print("PASS reset preserves other server credential")
        print("11 NAS client lifecycle checks passed")
    }
}
enum NASPasswordChecks {
    @MainActor static func run()async {
        let defaults=UserDefaults.standard,previous=defaults.object(forKey:"server.selected")
        defer{
            if let previous{defaults.set(previous,forKey:"server.selected")}else{defaults.removeObject(forKey:"server.selected")}
            NASFixture.passwordMode=false;NASFixture.passwordStatus=200
        }
        defaults.set("nas",forKey:"server.selected")
        var credentials:[ServerTarget:PairingCode]=[:]
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
        let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{credentials[ServerTarget.selected]},savePair:{credentials[ServerTarget.selected]=$0},removePair:{credentials[ServerTarget.selected]=nil},lookup:{_ in preconditionFailure("NAS cannot discover Android")})
        client.setForeground(false);NASFixture.publish()
        let calls=NASFixture.passwordCalls
        client.address="http://192.168.9.2:8089"
        await client.connect(password:"short")
        precondition(NASFixture.passwordCalls==calls);print("PASS invalid password stopped before exchange")
        await client.connect(password:"Synthetic-pass-42")
        precondition(NASFixture.passwordCalls==calls && client.error.contains("尚未开启"));print("PASS old NAS needs explicit password capability")
        NASFixture.passwordMode=true;client.address="http://192.168.9.3:8443"
        await client.connect(password:"Synthetic-pass-42")
        precondition(NASFixture.passwordCalls==calls && credentials[.nas]==nil);print("PASS upload endpoint never receives password")
        client.address="http://192.168.9.2:8089"
        let pinCalls=NASFixture.pinCalls;await client.connect(pin:"001234")
        precondition(NASFixture.pinCalls==pinCalls && client.error.contains("固定密码"));print("PASS fixed-password NAS does not downgrade to PIN")
        await client.connect(password:"Synthetic-pass-42")
        precondition(client.base != nil && client.error.isEmpty && credentials[.nas]?.token==NASFixture.token && client.secret==NASFixture.token)
        print("PASS password exchanged for random credential; password not persisted")
        let scope=client.recentScope!,saved=credentials[.nas]!
        let sent=NASFixture.passwordCalls;await client.reconnect()
        precondition(NASFixture.passwordCalls==sent && client.recentScope==scope);print("PASS reconnect uses existing credential without password")
        NASFixture.passwordStatus=403;await client.connect(password:"Synthetic-pass-42")
        precondition(client.error.contains("密码不正确") && credentials[.nas]?.token==saved.token && client.recentScope==scope)
        print("PASS wrong password preserves paired scope and gives correct error")
        NASFixture.passwordStatus=429;await client.connect(password:"Synthetic-pass-42")
        precondition(client.error.contains("15 分钟") && credentials[.nas]?.token==saved.token);print("PASS cooldown error preserves existing connection")
        await client.selectServer(.android);client.address="http://192.168.9.1:8088"
        let count=NASFixture.passwordCalls;await client.connect(password:"Synthetic-pass-42")
        precondition(NASFixture.passwordCalls==count);print("PASS Android rejects fixed-password flow")
        await client.connect(pin:"001234")
        precondition(client.base != nil && credentials[.android] != nil && credentials[.nas]?.token==saved.token)
        print("PASS Android PIN and separate NAS credential retained")
        client.setForeground(false)
        print("10 NAS fixed-password lifecycle checks passed")
    }
}
final class PairingFixture:URLProtocol {
    static let id="0123456789abcdef0123456789abcdef",token="abcdefghijklmnopqrstuvwxyzABCDEF"
    static let lock=NSLock()
    static var bookHosts:[String]=[]
    static var revision="a"
    static var pageNumbers=[1,3,10],pageHits=0
    static func setPages(_ numbers:[Int]){lock.lock();pageNumbers=numbers;lock.unlock()}
    static func hits()->Int{lock.lock();defer{lock.unlock()};return pageHits}
    static func changeRevision(){lock.lock();revision="b";lock.unlock()}
    static func hosts()->[String]{lock.lock();defer{lock.unlock()};return bookHosts}
    override class func canInit(with request:URLRequest)->Bool{request.url?.host?.hasPrefix("192.168.1.")==true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let url=request.url!,host=url.host!,body:Data
        if url.path=="/v2/pair" {
            precondition(request.httpMethod=="POST" && request.value(forHTTPHeaderField:"Authorization")==nil)
            var data=request.httpBody ?? Data()
            if let stream=request.httpBodyStream{stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:32);let size=stream.read(&buffer,maxLength:32);if size>0{data=Data(buffer.prefix(size))}}
            if data != Data("001234".utf8){
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:401,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocolDidFinishLoading(self);return
            }
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf","version":2,"deviceId":Self.id,"token":Self.token])
        }else if url.path=="/v2/identity" {
            precondition(request.value(forHTTPHeaderField:"Authorization")==nil)
            let nonce=URLComponents(url:url,resolvingAgainstBaseURL:true)!.queryItems!.first{$0.name=="nonce"}!.value!
            let message=Data("localshelf-server-v2\n\(Self.id)\n\(nonce)".utf8)
            let proof=HMAC<SHA256>.authenticationCode(for:message,using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.id,"proof":host=="192.168.1.124" ? proof : String(repeating:"0",count:64)])
        }else{
            Self.lock.lock();Self.bookHosts.append(host);Self.lock.unlock()
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            if ProcessInfo.processInfo.arguments.contains("--page-cache-checks"),url.path.hasSuffix("/pages") {
                Self.lock.lock();Self.pageHits+=1;let numbers=Self.pageNumbers;Self.lock.unlock()
                body=try! JSONEncoder().encode(Pages(pages:numbers.map{Page(number:$0)}))
            }else if ProcessInfo.processInfo.arguments.contains("--p34-checks") || ProcessInfo.processInfo.arguments.contains("--page-cache-checks") {
                let query=URLComponents(url:url,resolvingAgainstBaseURL:true)!.queryItems!
                let offset=Int(query.first{$0.name=="offset"}!.value!)!,limit=Int(query.first{$0.name=="limit"}!.value!)!
                Self.lock.lock();let revision=Self.revision;Self.lock.unlock()
                let books=(offset..<min(300,offset+limit)).map{Book(id:String($0+1),title:"Fixture-"+revision,rank:$0)}
                body=try! JSONEncoder().encode(BookList(orderVerified:true,total:300,books:books,catalogRevision:String(repeating:revision,count:64),libraryId:String(repeating:"c",count:64)))
            }else{body=Data("{\"orderVerified\":true,\"total\":1,\"books\":[{\"id\":\"1\",\"title\":\"Synthetic fixture\",\"rank\":0}]}".utf8)}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
final class TransferFixture:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{request.url?.host=="192.168.1.123"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let path=request.url!.path
        if path=="/wait" {return}
        if path=="/not-modified" {
            let response=HTTPURLResponse(url:request.url!,statusCode:304,httpVersion:"HTTP/1.1",headerFields:["ETag":"W/\""+String(repeating:"a",count:64)+"\""])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocolDidFinishLoading(self);return
        }
        let header=path=="/header" ? ["Content-Length":"99"] : [:]
        let response=HTTPURLResponse(url:request.url!,statusCode:path=="/status" ? 401 : 200,httpVersion:"HTTP/1.1",headerFields:header)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data([1,2,3]))
        client?.urlProtocol(self,didLoad:path=="/large" ? Data([4,5,6]) : Data([4,5]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
// Neutral, generated pages for gesture/layout QA; never accesses a real library.
enum ReaderDemo {
    @MainActor static var requests:[String:Int]=[:]
    @MainActor static func schedulingChecks()async {
        var count=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);count+=1;print("PASS \(message)")}
        func wait(_ test:()->Bool)async{for _ in 0..<500{if test(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("scheduling timeout")}
        let image=UIImage(systemName:"photo")!,queue=PageDecodeQueue(limit:1),gate=DispatchSemaphore(value:0)
        var completed:[String]=[],cancelled=0
        let first=Task{do{_ = try await queue.decode(key:"first"){gate.wait();return (image,false)}}catch{cancelled+=1}}
        await wait{queue.peak==1}
        let stale=Task{do{_ = try await queue.decode(key:"stale"){preconditionFailure("cancelled queued decode ran")}}catch{cancelled+=1}}
        await Task.yield();stale.cancel();first.cancel()
        let background=Task{_ = try? await queue.decode(key:"background"){(image,false)};completed.append("background")}
        await Task.yield()
        queue.prioritize("current")
        let current=Task{_ = try? await queue.decode(key:"current"){(image,false)};completed.append("current")}
        try? await Task.sleep(nanoseconds:50_000_000)
        pass(completed.isEmpty,"cancelled active ImageIO work retains physical decode slot")
        gate.signal();await first.value;await stale.value;await current.value;await background.value
        pass(cancelled==2,"queued and running cancellation resume their callers")
        pass(completed==["current","background"],"current page overtakes queued background decode")
        pass(queue.peak==1,"decode concurrency never exceeds configured limit")
        do{_ = try await queue.decode(key:"failure"){throw LibraryError.malformed};preconditionFailure("expected failure")}catch{}
        pass((try? await queue.decode(key:"after-failure"){(image,false)}) != nil,"decode failure releases slot")

        // Hold both physical slots to deterministically inspect logical request scheduling.
        let hold=DispatchSemaphore(value:0)
        let a=Task{try? await PageDecodeQueue.shared.decode(key:"hold-a"){hold.wait();return (image,false)}}
        let b=Task{try? await PageDecodeQueue.shared.decode(key:"hold-b"){hold.wait();return (image,false)}}
        await wait{PageDecodeQueue.shared.peak==2}
        let cache=ReadingCache(),library=Library(),pages=(1...9).map{Page(number:$0)}
        cache.update(library:library,book:"fixture",pages:pages,index:2)
        pass(cache.pendingPages==Set([3,4]),"initial logical requests are current and next page")
        await Task.yield()
        // A one-page reversal keeps both older jobs inside the normal window,
        // exercising current-demand preemption without triggering rapid mode.
        cache.update(library:library,book:"fixture",pages:pages,index:1)
        pass(cache.pendingPages==Set([2,3]),"new current page replaces lowest-priority speculative request")
        cache.update(library:library,book:"fixture",pages:pages,index:4)
        pass(cache.pendingPages==Set([5,6]),"multi-page jump drops reverse jobs under the existing rapid policy")
        cache.clear();hold.signal();hold.signal();_ = await a.value;_ = await b.value

        let root=FileManager.default.temporaryDirectory.appendingPathComponent("write-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let disk=CoverDiskCache(root:root),key=String(repeating:"a",count:64),ticket=await disk.ticket()
        var writeGate:CheckedContinuation<Void,Never>?,starts=0,delivered=false
        let writer=CoverWriteQueue{_ in starts+=1;await withCheckedContinuation{writeGate=$0}}
        let pipeline=CoverPipeline(disk:disk,writes:writer);pipeline.configureScope("fixture")
        pipeline.subscribe("/v1/books/1/cover",id:UUID(),load:{data("1")}){if case .success=$0{delivered=true}}
        await wait{delivered && writeGate != nil}
        pass(!writer.idle,"cover delivered while persistence is still blocked")
        writer.enqueue(Data(repeating:0,count:8*1024*1024),key:key,ticket:ticket,disk:disk)
        pass(writer.bytes<8*1024*1024,"staging budget includes the active write and rejects overflow")
        writer.enqueue(Data([1]),key:key,ticket:ticket,disk:disk)
        writer.cancel();writeGate?.resume();writeGate=nil;await wait{writer.idle}
        pass(starts==1 && writer.bytes==0,"reset drops staged writes and releases accounting")
        print("\(count) scheduling and staged-write checks passed")
    }
    @MainActor static func diskCoverChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func waitUntil(_ predicate:()->Bool)async{for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("disk/prefetch check timed out")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-check-"+UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        do {
            let folder=root.appendingPathComponent("lru"),disk=CoverDiskCache(root:folder,budget:360000)
            let keys=["a","b","c","d"].map{String(repeating:$0,count:64)},payload=Data(repeating:7,count:100000)
            let ticket=await disk.ticket()
            for key in keys.prefix(3){try await disk.put(payload,key:key,ticket:ticket)}
            pass(try await disk.value(keys[0])==payload,"disk cache reads stored bytes")
            try await disk.put(payload,key:keys[3],ticket:ticket)
            let oldest=try await disk.value(keys[1]),recent=try await disk.value(keys[0]),usage=try await disk.usage()
            pass(oldest==nil && recent==payload && usage<=360000,"allocated-size budget evicts least recently used cover")
            let restarted=CoverDiskCache(root:folder,budget:360000)
            pass(try await restarted.value(keys[0])==payload,"new cache instance restores persisted covers")
            pass(try folder.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup==true,"cover directory is excluded from backup")
            let old=await disk.ticket();try await disk.clear();try await disk.put(payload,key:keys[0],ticket:old)
            pass(try await disk.usage()==0,"clear generation rejects late writes")
            try await disk.put(Data(repeating:1,count:400000),key:keys[0],ticket:await disk.ticket())
            pass(try await disk.usage()==0,"oversized cover does not enter cache")
            let expired=CoverDiskCache(root:root.appendingPathComponent("expired"),budget:360000,ttl:0)
            try await expired.put(payload,key:keys[0],ticket:await expired.ticket())
            pass(try await expired.value(keys[0])==nil,"expired covers are removed")
            let pipelineDisk=CoverDiskCache(root:root.appendingPathComponent("pipeline"),budget:4_000_000),sample=data("1"),path="/v1/books/1/cover"
            let first=CoverPipeline(disk:pipelineDisk);first.configureScope("device/catalog")
            var loads=0,delivered=0
            func subscribe(_ pipeline:CoverPipeline,_ path:String){pipeline.subscribe(path,id:UUID(),load:{loads+=1;return sample}){if case .success=$0{delivered+=1}}}
            subscribe(first,path);await waitUntil{delivered==1}
            await waitUntil{first.writes.idle}
            let warm=CoverPipeline(disk:pipelineDisk);warm.configureScope("device/catalog");subscribe(warm,path);await waitUntil{delivered==2}
            pass(loads==1,"cold pipeline reuses disk cover without network fetch")
            warm.configureScope("device/changed");subscribe(warm,path);await waitUntil{delivered==3}
            pass(loads==2,"changed library cannot reuse previous library cover")
            let badKey=CoverRules.key(scope:"corrupt",path:path)!
            try await pipelineDisk.put(Data([1,2,3]),key:badKey,ticket:await pipelineDisk.ticket())
            warm.configureScope("corrupt");subscribe(warm,path);await waitUntil{delivered==4}
            pass(loads==3,"corrupt cached image falls back to validated network image")
            var late:CheckedContinuation<Data,Error>?
            warm.subscribe("/v1/books/2/cover",id:UUID(),load:{try await withCheckedThrowingContinuation{late=$0}}){_ in}
            await waitUntil{late != nil};warm.reset();try await pipelineDisk.clear();late?.resume(returning:sample)
            try? await Task.sleep(nanoseconds:100_000_000)
            pass(try await pipelineDisk.usage()==0,"in-flight fetch cannot repopulate a cleared cache")
        }catch{preconditionFailure("disk fixture failed: \(error)")}
        let queue=CoverPipeline(),sample=data("1")
        var starts:[String]=[],gates:[String:CheckedContinuation<Data,Error>]=[:],delivered=0
        func load(_ path:String)async throws->Data{starts.append(path);return try await withCheckedThrowingContinuation{gates[path]=$0}}
        queue.prefetch(["p","q"],load:load);await waitUntil{starts.count==1}
        pass(starts==["p"],"only one speculative cover starts at once")
        for path in ["a","b"]{queue.subscribe(path,id:UUID(),load:{try await load(path)}){if case .success=$0{delivered+=1}}}
        await waitUntil{starts.count==3}
        queue.subscribe("c",id:UUID(),load:{try await load("c")}){if case .success=$0{delivered+=1}}
        await waitUntil{starts.contains("c")}
        pass(!starts.contains("q"),"visible demand preempts speculative work and takes priority")
        gates.removeValue(forKey:"p")?.resume(returning:sample);queue.prefetch([],load:load)
        for path in ["a","b","c"]{gates.removeValue(forKey:path)?.resume(returning:sample)}
        await waitUntil{delivered==3}
        pass(!starts.contains("q"),"obsolete next-screen requests are removed")
        let promoted=CoverPipeline();var promotedStarts=0,promotedDone=false,promotedGate:CheckedContinuation<Data,Error>?
        promoted.prefetch(["same"]){_ in promotedStarts+=1;return try await withCheckedThrowingContinuation{promotedGate=$0}}
        await waitUntil{promotedGate != nil}
        promoted.subscribe("same",id:UUID(),load:{preconditionFailure("duplicate request")}){if case .success=$0{promotedDone=true}}
        promotedGate?.resume(returning:sample);await waitUntil{promotedDone}
        pass(promotedStarts==1,"prefetched cover promotes to visible without duplicate fetch")
        var stopGate:CheckedContinuation<Data,Error>?,stopStarts=0
        promoted.prefetch(["stop"]){_ in stopStarts+=1;return try await withCheckedThrowingContinuation{stopGate=$0}}
        await waitUntil{stopGate != nil};promoted.suspend(true);stopGate?.resume(returning:sample);promoted.suspend(false)
        try? await Task.sleep(nanoseconds:100_000_000)
        pass(stopStarts==1,"reader/background suspension removes speculative work")
        let demoted=CoverPipeline();let subscriber=UUID();var demotionGates:[String:CheckedContinuation<Data,Error>]=[:],cancelled=false
        func demotionLoad(_ path:String)async throws->Data{
            let result:Data=try await withCheckedThrowingContinuation{demotionGates[path]=$0}
            if path=="visible"{cancelled=Task.isCancelled};return result
        }
        demoted.subscribe("visible",id:subscriber,load:{try await demotionLoad("visible")}){_ in}
        demoted.prefetch(["visible","ahead"],load:demotionLoad)
        await waitUntil{demotionGates.count==2}
        demoted.cancel("visible",id:subscriber)
        demotionGates.removeValue(forKey:"visible")?.resume(returning:sample)
        await waitUntil{cancelled}
        demoted.prefetch([],load:demotionLoad);demotionGates.removeValue(forKey:"ahead")?.resume(returning:sample)
        pass(cancelled,"offscreen demand cannot become a second active prefetch")
        print("\(checks) disk and prefetch checks passed")
    }
    @MainActor static func sliderChecks(){
        let control=PositionControl(frame:CGRect(x:0,y:0,width:400,height:44));control.count=101
        var previews:[Int]=[],commits:[Int]=[],edits:[Bool]=[]
        control.preview={previews.append($0)};control.commit={commits.append($0)};control.editing={edits.append($0)}
        control.begin(at:CGPoint(x:200,y:22));precondition(control.value==50 && commits.isEmpty)
        control.finish(cancelled:false);precondition(commits==[50] && edits==[true,false]);print("PASS tap anywhere commits the tapped page exactly once")
        control.begin(at:CGPoint(x:18,y:22));for x in 20...380{control.update(at:CGPoint(x:x,y:22))}
        precondition(commits.count==1);control.update(at:CGPoint(x:500,y:22));control.finish(cancelled:false)
        precondition(commits==[50,100]);print("PASS drag previews without page requests until release, clamps last page")
        control.begin(at:CGPoint(x:18,y:22));control.finish(cancelled:true)
        precondition(control.value==100 && commits.count==2);print("PASS cancelled slider restores position without navigation")
        control.vertical=true;control.frame=CGRect(x:0,y:0,width:44,height:400)
        control.begin(at:CGPoint(x:22,y:-20));control.finish(cancelled:false);precondition(commits.last==0)
        control.begin(at:CGPoint(x:22,y:400));control.finish(cancelled:false);precondition(commits.last==100)
        print("PASS vertical shelf slider maps top to first and bottom to last")
        control.accessibilityDecrement();precondition(commits.last==99);control.accessibilityIncrement();precondition(commits.last==100)
        print("PASS VoiceOver adjustable actions navigate")
        let before=commits.count;control.isEnabled=false;control.begin(at:.zero);control.finish(cancelled:false);control.accessibilityDecrement()
        precondition(commits.count==before);control.isEnabled=true;control.count=1;control.begin(at:.zero);precondition(!control.scrubbing)
        print("PASS disabled and single-item sliders do not navigate")
        print("6 slider interaction checks passed")
    }
    @MainActor static func pairingChecks()async {
        let previous=UserDefaults.standard.object(forKey:"server.selected")
        UserDefaults.standard.set("android",forKey:"server.selected")
        defer{UserDefaults.standard.set(previous,forKey:"server.selected")}
        func waitUntil(_ test:()->Bool)async{for _ in 0..<500{if test(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("pairing test timeout")}
        var stored:PairingCode?
        func make(_ lookup:@escaping(String)async->[String]={_ in ["http://192.168.1.124:8088"]})->Library{
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingFixture.self]
            return Library(transport:LimitedHTTP(configuration:config),loadPair:{stored},savePair:{stored=$0},removePair:{stored=nil},lookup:lookup)
        }
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.1.124:8088",token:PairingFixture.token,deviceId:PairingFixture.id)
        let account="test-"+UUID().uuidString
        do {
            try PairingKeychain.save(code,account:account)
            let restored=try PairingKeychain.load(account:account)
            precondition(restored?.deviceId==code.deviceId && restored?.token==code.token)
            try PairingKeychain.save(PairingCode(app:"localshelf",version:2,address:"http://192.168.1.125:8088",token:code.token,deviceId:code.deviceId),account:account)
            let updated=try PairingKeychain.load(account:account);precondition(updated?.address=="http://192.168.1.125:8088")
            try PairingKeychain.remove(account:account);let deleted=try PairingKeychain.load(account:account);precondition(deleted==nil)
            print("PASS isolated system Keychain save read update and delete")
        }catch{try? PairingKeychain.remove(account:account);preconditionFailure("Keychain fixture failed: \((error as NSError).code)")}
        let first=make();await first.connect(code:code)
        precondition(stored?.deviceId==code.deviceId && first.total==1);print("PASS first pairing saved only after identity and library validation")
        let digits=make();digits.address=code.address;await digits.connect(pin:"001234")
        precondition(digits.base != nil && stored?.token==code.token && stored?.version==2);print("PASS six-digit POST exchanges for verified persistent identity")
        let wrongPIN=make();wrongPIN.address=code.address;await wrongPIN.connect(pin:"999999")
        precondition(wrongPIN.base==nil && !wrongPIN.error.isEmpty && stored?.token==code.token);print("PASS rejected PIN preserves existing pairing")
        let restarted=make();restarted.setForeground(true);await waitUntil{restarted.base != nil};restarted.setForeground(false)
        precondition(restarted.total==1);print("PASS app relaunch restores pairing and reconnects without QR")
        stored=PairingCode(app:"localshelf",version:2,address:"http://192.168.1.123:8088",token:code.token,deviceId:code.deviceId)
        let changedIP=make();changedIP.setForeground(true);await waitUntil{changedIP.base != nil};changedIP.setForeground(false)
        precondition(stored?.address==code.address);print("PASS discovery resolves changed IP and saves validated endpoint")
        precondition(PairingFixture.hosts().allSatisfy{$0=="192.168.1.124"});print("PASS fake old IP receives no bearer token")
        let invalid=PairingCode(app:"localshelf",version:2,address:"http://192.168.1.123:8088",token:code.token,deviceId:code.deviceId)
        let failed=make();await failed.connect(code:invalid)
        precondition(failed.base==nil && stored?.address==code.address);print("PASS failed new pairing does not overwrite saved pairing")
        let revoked=PairingCode(app:"localshelf",version:2,address:code.address,token:String(repeating:"X",count:32),deviceId:code.deviceId)
        let revokedLibrary=make();let before=PairingFixture.hosts().count;await revokedLibrary.connect(code:revoked)
        precondition(revokedLibrary.base==nil && PairingFixture.hosts().count==before);print("PASS revoked credentials rejected before authenticated requests")
        stored=invalid
        var looking=false
        let forgetting=make{_ in looking=true;try? await Task.sleep(nanoseconds:200_000_000);return [code.address]}
        forgetting.setForeground(true);await waitUntil{looking};forgetting.forget()
        try? await Task.sleep(nanoseconds:300_000_000);forgetting.setForeground(false)
        precondition(stored==nil && forgetting.paired==nil && forgetting.base==nil);print("PASS forgetting invalidates in-flight discovery and prevents restoring credentials")
        stored=invalid;looking=false
        let background=make{_ in looking=true;try? await Task.sleep(nanoseconds:200_000_000);return [code.address]}
        background.setForeground(true);await waitUntil{looking};background.setForeground(false)
        try? await Task.sleep(nanoseconds:300_000_000)
        precondition(background.base==nil && !background.loading);print("PASS backgrounding cancels reconnect and rejects late commits")
        first.forget();precondition(first.books.isEmpty && first.secret.isEmpty && stored==nil);print("PASS unpair clears visible data and in-memory credentials")
        print("12 pairing lifecycle checks passed")
    }
    @MainActor static func pagerChecks()async {
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("native pager test timed out")
        }
        let library=Library(),cache=ReadingCache(),pages=(1...3).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:1);await waitUntil{cache.images.count==3}
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
        var selections:[Int]=[];pager.select={selections.append($0)}
        pager.configure(cache:cache,pages:pages,index:1,resetID:0);pager.layoutIfNeeded()
        let identities=Set(pager.slots.map{ObjectIdentifier($0)})
        precondition(pager.slots.count==3);print("PASS three persistent native page slots")
        func requireCentered(_ canvas:ZoomCanvas,_ context:String){
            canvas.layoutIfNeeded()
            let visible=canvas.picture.convert(canvas.picture.bounds,to:canvas)
            precondition(abs(visible.midX-canvas.bounds.midX)<0.5 && abs(visible.midY-canvas.bounds.midY)<0.5,"Image not centered: \(context), image=\(visible), viewport=\(canvas.bounds), offset=\(canvas.scroll.contentOffset)")
        }
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"initial page")
        for distance in stride(from:0,through:150,by:5){pager.drag(CGSize(width:-distance,height:0),ended:false)}
        precondition(selections.isEmpty && pager.index==1 && pager.content.transform.tx == -150)
        print("PASS drag changes compositor transform without selection binding updates")
        pager.settle(target:2,animated:false)
        precondition(selections==[2] && pager.index==2 && pager.content.transform == .identity)
        print("PASS settle commits page once and recenters")
        requireCentered(pager.slots.first{$0.position==2}!.canvas,"after page turn")
        print("PASS displayed image remains centered after page turn")
        precondition(identities==Set(pager.slots.map{ObjectIdentifier($0)}));print("PASS page slots reused after navigation")
        pager.configure(cache:cache,pages:pages,index:0,resetID:1);pager.drag(CGSize(width:100,height:0),ended:false)
        precondition(abs(pager.content.transform.tx-18)<0.001 && selections==[2]);pager.cancelMotion()
        print("PASS first-page resistance and external jump without duplicate selection")
        pager.settle(target:1);pager.configure(cache:cache,pages:pages,index:2,resetID:2)
        try? await Task.sleep(nanoseconds:350_000_000)
        precondition(pager.index==2 && selections==[2] && !pager.motionActive)
        print("PASS slider jump invalidates obsolete animation completion")
        pager.configure(cache:cache,pages:pages,index:0,resetID:3);pager.settle(target:1)
        await waitUntil{!pager.motionActive};precondition(pager.index==1 && selections==[2,1])
        print("PASS native animation completes with one page notification")
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"animated page turn")
        print("PASS animated page turn preserves image center")
        for index in [2,1,0,1,2,1] {
            pager.settle(target:index,animated:false)
            requireCentered(pager.slots.first{$0.position==index}!.canvas,"repeated forward/backward turn")
        }
        print("PASS repeated forward/backward slot reuse stays centered")
        pager.frame.size=CGSize(width:844,height:390);pager.layoutIfNeeded()
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"landscape viewport")
        pager.frame.size=CGSize(width:390,height:844);pager.layoutIfNeeded()
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"portrait viewport")
        print("PASS viewport rotation centers both axes")
        let slot=pager.slots.first{$0.position==1}!
        var returns=0;pager.returnToLibrary={returns+=1}
        precondition(pager.edgeReturn.maximumNumberOfTouches==1 && PagingRules.returnEdgeWidth==48)
        slot.canvas.zoomChanged?(true)
        pager.finishEdgeReturn(translation:CGPoint(x:0,y:150),velocity:CGPoint(x:0,y:1000),ended:true);precondition(returns==0)
        pager.finishEdgeReturn(translation:CGPoint(x:100,y:0),velocity:.zero,ended:false);precondition(returns==0)
        pager.finishEdgeReturn(translation:CGPoint(x:100,y:0),velocity:.zero,ended:true);precondition(returns==1)
        slot.canvas.zoomChanged?(false)
        print("PASS only completed left-edge right swipe returns, including while zoomed")
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let landscape=UIGraphicsImageRenderer(size:CGSize(width:900,height:600),format:format).image{UIColor.white.setFill();$0.fill(CGRect(x:0,y:0,width:900,height:600))}
        slot.show(number:99,image:landscape,failed:false,active:true,reset:true);slot.layoutIfNeeded();slot.canvas.layoutIfNeeded()
        precondition(abs(slot.canvas.picture.bounds.width/slot.canvas.picture.bounds.height-1.5)<0.01)
        print("PASS reused canvas refits a different image aspect ratio")
        requireCentered(slot.canvas,"different image aspect ratio")
        for _ in 0..<3 {
            slot.show(number:99,image:landscape,failed:false,active:true,reset:true)
            requireCentered(slot.canvas,"unchanged centering inset after reset")
        }
        print("PASS same-inset resets and different image aspect ratios stay centered")
        let canvas=slot.canvas
        // Exercise retained layout math with a synthetic programmatic scale only.
        // Production has max=min=1 and no zoom gesture or UI entry point.
        precondition(canvas.scroll.maximumZoomScale==1 && canvas.scroll.pinchGestureRecognizer?.isEnabled != true)
        canvas.scroll.maximumZoomScale=5
        canvas.scroll.setZoomScale(2.5,animated:false)
        canvas.scroll.setContentOffset(CGPoint(x:80,y:-50),animated:false)
        let focalOffset=canvas.scroll.contentOffset,scale=canvas.scroll.zoomScale
        let detail=UIGraphicsImageRenderer(size:CGSize(width:1800,height:1200),format:format).image{UIColor.gray.setFill();$0.fill(CGRect(x:0,y:0,width:1800,height:1200))}
        slot.show(number:99,image:detail,failed:false,active:true,reset:false);canvas.layoutIfNeeded()
        precondition(canvas.scroll.contentOffset==focalOffset && canvas.scroll.zoomScale==scale)
        print("PASS zoomed detail replacement preserves focal offset and scale")
        canvas.scroll.setZoomScale(1,animated:false);canvas.layoutIfNeeded()
        requireCentered(canvas,"zoom back to fit")
        print("PASS zoom reset restores image center")
        canvas.scroll.setZoomScale(2.5,animated:false)
        slot.show(number:100,image:landscape,failed:false,active:true,reset:true)
        requireCentered(canvas,"recycle a zoomed page")
        print("PASS recycling a zoomed page restores image center")
        slot.show(number:99,image:nil,failed:true,active:true,reset:false)
        precondition(slot.canvas.picture.image==nil && !slot.retry.isHidden);print("PASS missing page releases image and exposes retry")
        pager.dispose();cache.clear();precondition(pager.slots.allSatisfy{$0.canvas.picture.image==nil})
        print("PASS leaving reader clears native image references")
        print("19 native pager checks passed")
    }
    @MainActor static func rapidPagerChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func waitUntil(line:UInt=#line,_ value:()->Bool)async{for _ in 0..<500{if value(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("rapid pager timeout at \(line)")}
        let library=Library(),cache=ReadingCache(),pages=(1...8).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:2);await waitUntil{cache.images.count==5}
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
        pager.configure(cache:cache,pages:pages,index:2,resetID:0)
        let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
        let window=UIWindow(windowScene:scene),host=UIViewController();host.view=pager;window.rootViewController=host;window.isHidden=false
        defer{window.isHidden=true;window.rootViewController=nil;pager.dispose();cache.clear()}
        pager.layoutIfNeeded();try? await Task.sleep(nanoseconds:50_000_000)
        var selections:[Int]=[],selectionResetID=0
        pager.select={target in selections.append(target);cache.update(library:library,book:"0",pages:pages,index:target);pager.configure(cache:cache,pages:pages,index:target,resetID:selectionResetID)}
        let identities=Set(pager.slots.map{ObjectIdentifier($0)}),span=pager.bounds.width+12
        pass(pager.pagePan.view === pager && pager.pagePan.maximumNumberOfTouches==1,"single container pan owns all visible pages")
        pager.settle(target:3);try? await Task.sleep(nanoseconds:60_000_000)
        let visible=pager.content.layer.presentation()!.affineTransform().tx
        pager.beginContact(at:CGPoint(x:100,y:300))
        let held=pager.content.transform.tx
        pass(!pager.motionActive && abs(held-visible)<2,"touch-down freezes the presentation position without snapping")
        try? await Task.sleep(nanoseconds:80_000_000)
        pass(abs(pager.content.transform.tx-held)<0.01,"held animation remains stationary before pan recognition")
        let incoming=pager.slots.first{$0.position==3}!,before=incoming.convert(.zero,to:pager).x
        let nearest=PagingRules.index(2+Int((-held/span).rounded()),count:pages.count)
        pager.beginDrag()
        pass(pager.index==nearest && abs(incoming.convert(.zero,to:pager).x-before)<0.5,"nearest-page rebase keeps visible pixels stationary")
        let origin=pager.content.transform.tx
        pager.drag(CGSize(width:-25,height:0),ended:false)
        pass(abs(pager.content.transform.tx-(origin-25))<0.01,"interrupted page follows the next finger delta one-to-one")
        pager.drag(CGSize(width:-25,height:0),ended:true,velocityX:-1400)
        await waitUntil{!pager.motionActive}
        pass(pager.index==nearest+1,"short fast continuation advances beyond the caught page")
        pass(selections==Array(Set(selections)).sorted(),"interrupted completion cannot duplicate or reverse committed page order")
        pass(Set(pager.slots.map{ObjectIdentifier($0)})==identities,"rapid handoff retains three reusable page slots")
        pager.settle(target:pager.index+1);try? await Task.sleep(nanoseconds:60_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag();let caught=pager.index
        pager.drag(CGSize(width:25,height:0),ended:true,velocityX:1400)
        await waitUntil{!pager.motionActive}
        pass(pager.index==caught-1,"fast reversal takes over the moving page instead of being ignored")
        for direction in [1,1,-1,1,-1,-1] {
            pager.settle(target:PagingRules.index(pager.index+direction,count:pages.count))
            try? await Task.sleep(nanoseconds:35_000_000)
            pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag()
            let base=pager.index,target=PagingRules.index(base+direction,count:pages.count)
            pager.drag(CGSize(width:CGFloat(-direction*24),height:0),ended:true,velocityX:CGFloat(-direction*1500))
            await waitUntil{!pager.motionActive}
            precondition(pager.index==target && pager.content.transform == .identity)
        }
        pass(true,"six alternating in-flight handoffs keep page state and transforms consistent")
        let current=pager.index,next=PagingRules.index(current+1,count:pages.count)
        pager.settle(target:next);try? await Task.sleep(nanoseconds:30_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.finishContact()
        await waitUntil{!pager.motionActive}
        pass(pager.index==next,"tap or rejected pan resumes the held settle")
        pager.configure(cache:cache,pages:pages,index:0,resetID:1)
        pager.drag(CGSize(width:120,height:0),ended:false);pager.settle(target:0)
        try? await Task.sleep(nanoseconds:30_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));let bounce=pager.content.transform.tx
        pager.beginDrag();pager.drag(.zero,ended:false)
        pass(abs(pager.content.transform.tx-bounce)<0.5,"catching boundary bounce does not apply resistance twice")
        pager.cancelMotion();let startIndex=pager.index
        let canvas=pager.slots.first{$0.position==startIndex}!.canvas
        pass(canvas.scroll.maximumZoomScale==1 && canvas.scroll.pinchGestureRecognizer?.isEnabled != true,"reader has no enabled pinch zoom")
        pass(!(canvas.scroll.gestureRecognizers ?? []).contains{($0 as? UITapGestureRecognizer)?.numberOfTapsRequired==2},"reader has no double-tap zoom recognizer")
        canvas.scroll.setZoomScale(1,animated:false);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pager.settle(target:1);try? await Task.sleep(nanoseconds:25_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag();pager.drag(CGSize(width:-50,height:0),ended:false)
        pager.configure(cache:cache,pages:pages,index:6,resetID:3)
        try? await Task.sleep(nanoseconds:300_000_000)
        pass(pager.index==6 && !pager.motionActive && pager.content.transform == .identity,"external jump invalidates interrupted motion and drag origin")
        pager.settle(target:7);pager.beginContact(at:CGPoint(x:100,y:300));pager.endPresentation();pager.finishContact()
        try? await Task.sleep(nanoseconds:300_000_000)
        pass(!pager.motionActive && pager.animationPlayer.key==nil,"exit while a settle is held cannot resume it later")
        // Exercise a second pan BEFORE the first page reaches its midpoint,
        // including a low-speed release rather than only synthetic 1400 pt/s.
        selectionResetID=4
        for (delta,cancelled,resume,expected) in [(-16.0,false,true,3),(-16.0,true,true,2),(-16.0,false,false,2),(16.0,false,true,2)] {
            pager.configure(cache:cache,pages:pages,index:2,resetID:4)
            // Separate test cases with a presented reset frame. Otherwise the
            // previous case's presentation layer can be sampled as this turn's
            // starting offset (also reproducible in the unmodified 0.4.25 build).
            CATransaction.flush();try? await Task.sleep(nanoseconds:50_000_000)
            pager.settle(target:3);pager.beginContact(at:CGPoint(x:195,y:300));pager.beginDrag()
            precondition(pager.index==2)
            let held=pager.content.transform.tx
            pager.drag(CGSize(width:delta,height:0),ended:false)
            pass(abs(pager.content.transform.tx-(held+delta))<0.5,"early short catch follows finger without jumping")
            pager.drag(CGSize(width:delta,height:0),ended:true,velocityX:0,cancelled:cancelled,resumeInterrupted:resume)
            await waitUntil{!pager.motionActive}
            pass(pager.index==expected && pager.content.transform == .identity,"short catch resumes only same-direction non-cancelled non-held turn")
        }
        selectionResetID=5
        for (delta,cancelled,resume,expected) in [(-16.0,false,true,3),(-16.0,true,true,2),(-16.0,false,false,2),(16.0,false,true,2)] {
            pager.configure(cache:cache,pages:pages,index:2,resetID:5)
            CATransaction.flush();try? await Task.sleep(nanoseconds:50_000_000)
            let original=pager.slots.first{$0.position==2}!
            pager.settle(target:3);pager.beginContact(at:CGPoint(x:195,y:300))
            let visible=original.convert(.zero,to:pager).x
            pager.beginDrag(direction:-24)
            pass(pager.index==3 && abs(original.convert(.zero,to:pager).x-visible)<0.5,"early forward intent carries accepted destination without moving pixels")
            pager.drag(CGSize(width:delta,height:0),ended:true,velocityX:0,cancelled:cancelled,resumeInterrupted:resume)
            await waitUntil{!pager.motionActive}
            pass(pager.index==expected && pager.content.transform == .identity,"carried destination still respects pause, cancellation and opposite short movement")
        }
        for interval:UInt64 in [20_000_000,50_000_000,90_000_000] {
            pager.configure(cache:cache,pages:pages,index:1,resetID:5)
            CATransaction.flush();try? await Task.sleep(nanoseconds:50_000_000)
            for _ in 0..<3 {
                pager.beginContact(at:CGPoint(x:195,y:300))
                let visibleSlots=pager.slots.filter{slot in let frame=slot.convert(slot.bounds,to:pager);return !slot.isHidden && frame.intersects(pager.bounds)}
                let positions=visibleSlots.map{($0,$0.convert(.zero,to:pager).x)}
                pager.beginDrag(direction:-24)
                pass(positions.allSatisfy{!$0.0.isHidden && abs($0.0.convert(.zero,to:pager).x-$0.1)<0.5},"rapid forward rebase keeps every visible page in its original position")
                let base=pager.index
                pager.drag(CGSize(width:-24,height:0),ended:true,velocityX:-400)
                try? await Task.sleep(nanoseconds:interval)
                pass(pager.index>=base,"back-to-back decelerated flick cannot reverse the current page")
            }
            await waitUntil{!pager.motionActive}
            pass((3...4).contains(pager.index) && pager.content.transform == .identity,"extremely rapid input remains bounded without dropping visible slots or off-centering")
        }
        print("\(checks) rapid pager checks passed")
    }
    @MainActor static func performanceChecks()async {
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("performance test timed out")
        }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TransferFixture.self]
        let transport=LimitedHTTP(configuration:config)
        func request(_ path:String)->URLRequest {URLRequest(url:URL(string:"http://192.168.1.123/"+path)!)}
        do{
            let parallelRequest=request("ok")
            let bytes=try await withThrowingTaskGroup(of:Int.self){group in
                for _ in 0..<6{group.addTask{try await transport.data(parallelRequest,limit:5).count}}
                var sum=0;for try await count in group{sum+=count};return sum
            }
            precondition(bytes==30);print("PASS concurrent transport initialization and request isolation")
            let data=try await transport.data(request("ok"),limit:5);precondition(data.count==5);print("PASS chunked exact limit")
            let validated=try await transport.response(request("not-modified"),limit:5,allowNotModified:true)
            precondition(validated.status==304 && validated.data.isEmpty && validated.etag != nil);print("PASS explicit conditional transport accepts zero-body 304 and preserves ETag")
            for path in ["large","header","status","not-modified"] {
                do{_=try await transport.data(request(path),limit:5);preconditionFailure("response should fail")}
                catch{print("PASS transport rejects \(path)")}
            }
            let waiting=Task{try await transport.data(request("wait"),limit:5)}
            await Task.yield();waiting.cancel()
            do{_=try await waiting.value;preconditionFailure("cancellation ignored")}catch{print("PASS transport cancellation")}
        }catch{preconditionFailure("transport fixture failed: \(error)")}
        transport.close()
        let library=Library(),cache=ReadingCache(),pages=(1...5).map{Page(number:$0)}
        requests.removeAll();cache.update(library:library,book:"0",pages:pages,index:2)
        await waitUntil{cache.images.count==5}
        precondition(cache.retainedBytes<=ReadingBudget.normal);print("PASS reading retained budget")
        let path="/v1/books/0/pages/3",before=requests[path]
        cache.loadDetail(3);await waitUntil{cache.detailImage != nil || cache.detailFailed}
        precondition(cache.detailImage != nil && requests[path]==before && cache.retainedBytes<=ReadingBudget.normal);print("PASS zoom reuses compressed page without network fetch")
        cache.memoryPressure();let requestCount=requests.values.reduce(0,+)
        await Task.yield()
        precondition(cache.reducedMemory && Set(cache.images.keys)==Set([3]) && cache.detailImage==nil && cache.retainedBytes<=ReadingBudget.pressure && requests.values.reduce(0,+)==requestCount)
        print("PASS memory warning keeps current page without rewarming neighbors")
        cache.update(library:library,book:"0",pages:pages,index:3);await waitUntil{cache.images[4] != nil}
        precondition(cache.images.count==1);print("PASS pressure mode only requests current page after navigation")
        cache.restorePrefetch();cache.update(library:library,book:"0",pages:pages,index:3)
        await waitUntil{cache.images.count==4};precondition(cache.retainedBytes<=ReadingBudget.normal);print("PASS explicit prefetch recovery")
        cache.clear();precondition(cache.images.isEmpty && cache.retainedBytes==0);print("PASS reader exit releases retained data")
        print("12 runtime performance checks passed")
        let adaptive=ReadingCache(),many=(1...9).map{Page(number:$0)}
        adaptive.update(library:library,book:"0",pages:many,index:3)
        adaptive.update(library:library,book:"0",pages:many,index:4)
        adaptive.update(library:library,book:"0",pages:many,index:5)
        precondition(adaptive.prefetchPages==[6,7,8] && adaptive.animationWarmPages==[6,7])
        print("PASS rapid navigation reduces speculative reverse work")
        adaptive.update(library:library,book:"0",pages:many,index:4)
        precondition(adaptive.prefetchPages==[5,4,3] && adaptive.animationWarmPages==[5,4])
        print("PASS reversal immediately reprioritizes current direction")
        await waitUntil{adaptive.prefetchPages==[5,4,6,3,7]}
        precondition(adaptive.animationWarmPages==[5,4,6])
        print("PASS settle automatically restores both neighboring GIF sessions")
        adaptive.setThermalState(.serious)
        precondition(adaptive.prefetchPages==[5,4] && adaptive.animationWarmPages==[5])
        adaptive.setThermalState(.critical);precondition(adaptive.prefetchPages==[5])
        adaptive.setThermalState(.nominal);precondition(adaptive.prefetchPages==[5,4,6,3,7])
        print("PASS thermal throttling recovers without moving the current page")
        adaptive.update(library:library,book:"0",pages:many,index:6);adaptive.memoryPressure()
        try? await Task.sleep(nanoseconds:550_000_000)
        precondition(adaptive.prefetchPages==[7] && adaptive.reducedMemory)
        print("PASS settle timer cannot bypass memory warning protection")
        adaptive.clear();try? await Task.sleep(nanoseconds:550_000_000)
        precondition(adaptive.prefetchPages.isEmpty && adaptive.animationWarmPages.isEmpty && adaptive.retainedBytes==0)
        print("PASS exit cancels adaptive recovery and releases retained data")
    }
    @MainActor static func coverChecks()async {
        let pipeline=CoverPipeline(),sample=data("1")
        var started=0,delivered=0,cancelledDelivery=0
        var gates:[String:CheckedContinuation<Data,Error>]=[:]
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500 {if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("cover check timed out")
        }
        pipeline.suspend(true)
        let first=UUID(),second=UUID(),queued=UUID()
        for (path,id) in [("a",first),("a",second),("b",UUID()),("c",UUID()),("d",queued)] {
            pipeline.subscribe(path,id:id,load:{started+=1;return try await withCheckedThrowingContinuation{gates[path]=$0}}){result in
                if id==first {cancelledDelivery+=1};if case .success=result{delivered+=1}
            }
        }
        precondition(started==0);print("PASS suspended cover queue")
        pipeline.suspend(false);await waitUntil{started==3}
        precondition(gates.count==3 && gates["d"]==nil);print("PASS concurrency limit and same-path merge")
        pipeline.cancel("a",id:first);pipeline.cancel("d",id:queued)
        for key in ["a","b","c"]{gates.removeValue(forKey:key)?.resume(returning:sample)}
        await waitUntil{delivered==3}
        precondition(started==3 && cancelledDelivery==0);print("PASS one subscriber cancellation preserves other, queued work removed")
        var hit=false
        pipeline.subscribe("a",id:UUID(),load:{preconditionFailure("cache missed")}){if case .success=$0{hit=true}}
        precondition(hit);print("PASS decoded cover cache hit")
        pipeline.trim();var reloaded=false
        pipeline.subscribe("a",id:UUID(),load:{started+=1;return sample}){if case .success=$0{reloaded=true}}
        await waitUntil{reloaded};precondition(started==4);print("PASS memory trim reload")
        var oldGate:CheckedContinuation<Data,Error>?,oldCancelled=false,newDelivered=false
        pipeline.subscribe("stale",id:UUID(),load:{try await withCheckedThrowingContinuation{oldGate=$0}}){if case .failure(let e)=$0{oldCancelled=e is CancellationError}}
        await waitUntil{oldGate != nil};pipeline.reset();precondition(oldCancelled)
        pipeline.subscribe("stale",id:UUID(),load:{sample}){if case .success=$0{newDelivered=true}}
        oldGate?.resume(returning:sample);await waitUntil{newDelivered}
        print("PASS source reset rejects stale in-flight result")
        print("6 cover pipeline checks passed")
    }
    static var largeAnimationFixture=false
    static var animationPaddingBytes=9*1024*1024
    static func animationData(_ path:String)->Data {
        if path.hasSuffix("/pages"){return Data("{\"pages\":[{\"number\":1},{\"number\":2},{\"number\":3},{\"number\":4}]}".utf8)}
        // Synthetic optimized partial-frame GIF, APNG and lossless WebP.
        let samples=[
            "R0lGODlhIAAgAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAIAAgAAAINQABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJUmRAACH5BAEUAAIALAgACAAQABAAgf8AAAD/AAAAAAAAAAgdAAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWBAQEAIfkEAR4AAgAsAAAAABgAGACB/wAAAAD/AAAAAAAACF4AAwgcKFCAwYMIEwogSFChw4MMBz58GLHgRIUVA1zEWHFjwoweEYIMeRGAyZMoUwJ4qLLlSZYuW8KMmXImzZcOb9bMqROnwp4+EwI1aVNn0ZtHaSaNudRlU5k8gQYEADs=",
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAAAgAAAAIAAAAAAAAAAAAAEACgAAmicj6gAAACxJREFUeNrtzjEBAAAIA6Bp/84zhg8kYJo0jzbPBAQEBAQEBAQEBAQEBAQEDjDjAj6yKjtjAAAAGmZjVEwAAAABAAAAEAAAABAAAAAIAAAACAABAAUAAHpFze4AAAAhZmRBVAAAAAJ42mNk+M/wn4ECwMRAIRg1YNSAUQMGiwEAV24CHhEdCFMAAAAaZmNUTAAAAAMAAAAYAAAAGAAAAAAAAAAAAAMACgAAqUt0egAAADRmZEFUAAAABHja7dDBDQAgDMNAh/13DhvwqfrCXuAkB1oelTDpsJyAwLwU6iIBAQGB74EL/EsFKwePTzgAAAAASUVORK5CYII=",
            "UklGRswAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAB8AAB8AAGQAAAJWUDhMDwAAAC8fwAcABxD9j/4HIqL/AQBBTk1GKAAAAAQAAAQAAA8AAA8AAMgAAABWUDhMDwAAAC8PwAMAB9D/iP4HIqL/AQBBTk1GQAAAAAAAAAAAABcAABcAACwBAABWUDhMJwAAAC8XwAUQFxDzLyAo8n+0+Q/4gEzapiZnsjb3jQmI6P8YJAA7jeoxAQA="
        ]
        if let number=Int(path.split(separator:"/").last ?? ""),(1...3).contains(number){var data=Data(base64Encoded:samples[number-1])!;if largeAnimationFixture && number<=2{data.append(Data(repeating:0,count:animationPaddingBytes))};return data}
        return data("1")
    }
    @MainActor static func animationChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)");fflush(stdout)}
        func waitUntil(line:UInt=#line,info:()->String={""},_ value:()->Bool)async{for _ in 0..<500{if value(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("animation check timed out at \(line): \(info())")}
        func pixel(_ image:UIImage)->[UInt8]{
            var bytes=[UInt8](repeating:0,count:32*32*4)
            bytes.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image.cgImage!,in:CGRect(x:0,y:0,width:32,height:32))}
            let i=(16*32+16)*4;return Array(bytes[i..<i+3])
        }
        do{
            let decoder=AnimationDecoder()
            for (i,name) in ["GIF","APNG","WebP"].enumerated(){
                let ticket=UUID(),info=try await decoder.open(animationData("\(i+1)"),ticket:ticket)
                pass(info.count==3 && info.plays==0,"\(name) detects three frames and infinite loop")
                let a=try await decoder.frame(0,ticket:ticket),b=try await decoder.frame(1,ticket:ticket),c=try await decoder.frame(2,ticket:ticket)
                pass(a.0.cgImage!.width==32 && b.0.cgImage!.width==32 && c.0.cgImage!.width==32,"\(name) full canvas for partial frames")
                pass(pixel(a.0)==[255,0,0] && pixel(b.0)==[0,255,0] && pixel(c.0)==[255,0,0],"\(name) frame sequence and composition")
                pass(abs(a.1-0.1)<0.001 && abs(b.1-0.2)<0.001 && abs(c.1-0.3)<0.001,"\(name) individual frame durations")
                await decoder.close(ticket)
            }
            pass(AnimationLimits.delay(0)==0.1 && AnimationLimits.delay(.nan)==0.1,"invalid frame duration bounded")
            var finite=animationData("1")
            let loop=finite.range(of:Data("NETSCAPE2.0".utf8))!.upperBound+2;finite[loop]=1
            let finiteInfo=try await decoder.open(finite,ticket:UUID())
            pass(finiteInfo.plays==2,"GIF finite loop means first play plus one repetition")
            var webp=animationData("3");let webpLoop=webp.range(of:Data("ANIM".utf8))!.lowerBound+12;webp[webpLoop]=1
            let webpInfo=try await decoder.open(webp,ticket:UUID());pass(webpInfo.plays==1,"WebP finite loop means total plays")
            var large=animationData("1")
            for start in [6,large.range(of:Data([0x2c,0,0,0,0,32,0,32,0]))!.lowerBound+5]{large[start]=0x88;large[start+1]=0x13;large[start+2]=0x88;large[start+3]=0x13}
            do{_ = try await decoder.open(large,ticket:UUID());preconditionFailure("oversized canvas accepted")}catch{}
            pass(true,"oversized canvas is rejected before frame decoding")
            do{_ = try await decoder.open(Data(repeating:0,count:AnimationLimits.compressed+1),ticket:UUID());preconditionFailure("oversized animation accepted")}catch{}
            pass(true,"oversized input rejected before frame decoding")
        }catch{preconditionFailure("animation fixture failed: \(error)")}
        let player=AnimatedPagePlayer();var frames=0,failures=0
        player.play(key:"gif",load:{animationData("1")},display:{_ in frames+=1},failed:{_ in failures+=1})
        await waitUntil{frames>=4};pass(failures==0,"player advances through loop")
        player.stop();let stopped=frames;try? await Task.sleep(nanoseconds:400_000_000)
        pass(frames==stopped && player.key==nil,"stop prevents late frame display")
        var finite=animationData("1");finite[finite.range(of:Data("NETSCAPE2.0".utf8))!.upperBound+2]=1
        var finiteFrames=0
        player.play(key:"finite",load:{finite},display:{_ in finiteFrames+=1},failed:{_ in preconditionFailure("finite playback failed")})
        await waitUntil{finiteFrames==6};try? await Task.sleep(nanoseconds:500_000_000)
        pass(finiteFrames==6,"finite animation stops on its final frame");player.stop()
        let library=Library(),cache=ReadingCache(),pages=(1...4).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:0);await waitUntil{cache.images.count>=3}
        pass(cache.animated==Set([1,2,3]),"cache detects animation without playing neighbors")
        pass(cache.retainedBytes<=ReadingBudget.normal,"animation reservation fits reading budget")
        await waitUntil{cache.preparedAnimation(1) != nil && cache.preparedAnimation(2) != nil}
        let firstPrepared=cache.preparedAnimation(1)!,nextPrepared=cache.preparedAnimation(2)!
        pass(cache.animationPreheater.used<=AnimationLimits.reserve-10*1024*1024,"prepared data and first two frames obey shared budget")
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844));pager.configure(cache:cache,pages:pages,index:0,resetID:0);pager.layoutIfNeeded()
        await waitUntil{pager.animationPlayer.displayedFrames>=3}
        pass(pager.animationPlayer.key=="1","only current native page plays")
        let requestCount=requests["/v1/books/0/pages/2"]
        cache.update(library:library,book:"0",pages:pages,index:1);pager.configure(cache:cache,pages:pages,index:1,resetID:1)
        pass(pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.first.0,"warm page displays its prepared first frame synchronously")
        pass(cache.preparedAnimation(2) === nextPrepared && requests["/v1/books/0/pages/2"]==requestCount,"handoff reuses decoder and compressed bytes without network")
        await waitUntil{cache.preparedAnimation(3) != nil}
        pass(cache.preparedAnimation(1) === firstPrepared,"previous animation stays prepared within budget")
        cache.update(library:library,book:"0",pages:pages,index:0);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pass(pager.slots.first{$0.position==0}?.canvas.picture.image === firstPrepared.first.0,"reverse navigation directly reuses prepared previous page")
        // UIKit completes off-window animations early; use a visible synthetic host
        // when checking overlap between actual settling and frame presentation.
        let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
        let window=UIWindow(windowScene:scene),host=UIViewController()
        host.view=pager;window.rootViewController=host;window.isHidden=false
        defer{window.isHidden=true;window.rootViewController=nil}
        pager.setNeedsLayout();pager.layoutIfNeeded()
        try? await Task.sleep(nanoseconds:50_000_000)
        var committed:[Int]=[]
        pager.select={target in committed.append(target);cache.update(library:library,book:"0",pages:pages,index:target);pager.configure(cache:cache,pages:pages,index:target,resetID:2)}
        pager.drag(CGSize(width:-80,height:0),ended:false)
        pass(pager.animationPlayer.key=="1" && committed.isEmpty,"tentative drag does not play the neighbor or commit its page")
        pager.cancelMotion()
        let began=ContinuousClock.now,starts=pager.animationPlayer.playbackStarts,frameCount=pager.animationPlayer.displayedFrames
        pager.settle(target:1)
        let elapsed=began.duration(to:.now)
        pass(elapsed < .milliseconds(100) && pager.animationPlayer.key=="2" && pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.first.0,"warm committed turn attaches incoming first frame within 100 ms")
        print("METRIC warm handoff main-thread attachment: \(elapsed)")
        pass(pager.motionActive && pager.index==0 && committed.isEmpty,"incoming playback starts before settle without early page selection")
        await waitUntil{pager.animationPlayer.displayedFrames>=frameCount+2}
        print("METRIC incoming second frame: \(began.duration(to:.now)); motion=\(pager.motionActive); key=\(pager.animationPlayer.key ?? "none"); starts=\(pager.animationPlayer.playbackStarts-starts); second=\(pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.second.0)")
        pass(pager.motionActive && pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.second.0,"incoming second frame plays while the page is still settling")
        await waitUntil{!pager.motionActive}
        pass(pager.index==1 && committed==[1] && pager.animationPlayer.playbackStarts==starts+1,"settle completion keeps playback timeline without restarting")
        let centered=pager.slots.first{$0.position==1}!.canvas
        let imageFrame=centered.picture.convert(centered.picture.bounds,to:centered)
        pass(abs(imageFrame.midY-centered.bounds.midY)<1 && abs(imageFrame.midX-centered.bounds.midX)<1,"early playback preserves centered image after settling")
        pager.settle(target:0);pager.cancelMotion()
        pass(pager.index==1 && pager.animationPlayer.key=="2","cancelled incoming transition resumes the original page")
        pager.settle(target:0);cache.setAnimationForeground(false);pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        await waitUntil{!pager.motionActive}
        pass(pager.animationPlayer.key==nil,"background during settling cannot restart incoming playback")
        cache.setAnimationForeground(true);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pager.settle(target:1)
        cache.update(library:library,book:"0",pages:pages,index:3);pager.configure(cache:cache,pages:pages,index:3,resetID:3)
        try? await Task.sleep(nanoseconds:350_000_000)
        pass(pager.index==3 && pager.animationPlayer.key==nil && !pager.motionActive,"external static-page jump rejects incoming frames and stale settle completion")
        cache.update(library:library,book:"0",pages:pages,index:0);pager.configure(cache:cache,pages:pages,index:0,resetID:4)
        pager.select=nil
        cache.setAnimationForeground(false);pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        pass(pager.animationPlayer.key==nil,"background stops animation")
        cache.setAnimationForeground(true);pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        cache.toggleAnimation();pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        pass(pager.animationPlayer.key==nil,"manual pause stops animation")
        cache.update(library:library,book:"0",pages:pages,index:3);await waitUntil{cache.images[4] != nil};pager.configure(cache:cache,pages:pages,index:3,resetID:1)
        pass(pager.animationPlayer.key==nil && !cache.animationPaused,"static next page stops playback")
        cache.update(library:library,book:"0",pages:pages,index:1);await waitUntil{cache.images[2] != nil};pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        pager.settle(target:0);pager.endPresentation()
        try? await Task.sleep(nanoseconds:350_000_000)
        pass(pager.animationPlayer.key==nil && !pager.motionActive,"leaving a settling reader cannot restart playback after view disappearance")
        cache.memoryPressure();pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        pass(pager.animationPlayer.key==nil && cache.retainedBytes<=ReadingBudget.pressure,"memory pressure stops playback")
        pager.dispose();cache.clear();pass(cache.retainedBytes==0 && cache.animated.isEmpty,"exit releases playback and cache")
        pass(cache.animationPreheater.used==0,"exit clears prepared source pool")
        largeAnimationFixture=true
        let bigLibrary=Library(),big=ReadingCache();let bigPath="/v1/books/0/pages/1",before=requests["/v1/books/0/pages/1",default:0]
        big.update(library:bigLibrary,book:"0",pages:pages,index:0)
        await waitUntil{big.preparedAnimation(1) != nil}
        await waitUntil(info:{big.animationPreheater.debugState}){big.preparedAnimation(2) != nil}
        pass(big.preparedAnimation(2) != nil,"large neighboring input is staged until decoder budget is available")
        do{let prepared=try await big.prepareAnimation(1);pass(prepared === big.preparedAnimation(1) && requests[bigPath,default:0]==before+1,"file larger than old 8 MiB cache is not downloaded twice")}catch{preconditionFailure("large warm handoff failed")}
        pass(big.retainedBytes<=ReadingBudget.normal && big.animationPreheater.used<=AnimationLimits.reserve-10*1024*1024,"large prepared source remains bounded")
        big.clear();largeAnimationFixture=false
        let reordered=AnimationPreheater();reordered.configure([1,2])
        var padded=animationData("1");padded.append(Data(repeating:0,count:9*1024*1024))
        reordered.offer(2,data:padded);reordered.offer(1,data:padded)
        await waitUntil{reordered.value(1) != nil && reordered.value(2) != nil}
        pass(reordered.used<=AnimationLimits.reserve-10*1024*1024,"neighbor arriving first retains bytes when current page takes priority")
        reordered.clear()
        let isolated=AnimationPreheater();isolated.configure([1]);isolated.offer(1,data:animationData("1"));isolated.clear()
        try? await Task.sleep(nanoseconds:100_000_000)
        pass(isolated.value(1)==nil && isolated.used==0,"cleared preheat jobs cannot resurrect stale sources")
        print("\(checks) animation checks passed")
    }
    static func data(_ path:String)->Data {
        if path.hasSuffix("/pages"){return Data("{\"pages\":[{\"number\":1},{\"number\":2},{\"number\":3}]}".utf8)}
        let number=Int(path.split(separator:"/").last ?? "1") ?? 1
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:1200,height:1800),format:format).jpegData(withCompressionQuality:0.9){context in
            UIColor(white:0.94,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1200,height:1800))
            let colors:[UIColor]=[.systemTeal,.systemIndigo,.systemOrange]
            for row in 0..<6 {for col in 0..<4 {
                colors[(number-1)%3].withAlphaComponent(CGFloat(row+col+2)/12).setFill()
                context.fill(CGRect(x:CGFloat(col*300+8),y:CGFloat(row*300+8),width:284,height:284))
                "\(row+1)-\(col+1)".draw(at:CGPoint(x:CGFloat(col*300+30),y:CGFloat(row*300+35)),withAttributes:[.font:UIFont.systemFont(ofSize:40),.foregroundColor:UIColor.black])
            }}
            "PAGE \(number)".draw(at:CGPoint(x:280,y:830),withAttributes:[.font:UIFont.boldSystemFont(ofSize:130),.foregroundColor:UIColor.black])
        }
    }
}
struct ReaderDemoView:View {
    @StateObject private var library=Library()
    var body:some View {NavigationStack{Reader(library:library,book:Book(id:"0",title:"阅读测试 · 合成网格",rank:0))}}
}
struct ShelfDemoView:View {
    @StateObject private var library=Library(loadPair:{nil},savePair:{_ in},removePair:{})
    var body:some View {ShelfView(library:library).task{
        library.base=URL(string:"http://192.168.1.123:8088");library.pageSize=500
        await library.loadPage(0)
        if ProcessInfo.processInfo.arguments.contains("--shelf-jump-checks"){
            @MainActor func allViews(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap{allViews($0)}}
            @MainActor func views()->[UIView]{UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap{$0.windows}.flatMap{allViews($0)}}
            @MainActor func settled() async{try? await Task.sleep(nanoseconds:600_000_000)}
            @MainActor func slider(count:Int) async->PositionControl{
                for _ in 0..<500{
                    if !library.loading,library.books.count==count,let control=views().compactMap({$0 as? PositionControl}).first(where:{$0.vertical && $0.count==count && $0.isEnabled}){await settled();return control}
                    try? await Task.sleep(nanoseconds:10_000_000)
                };preconditionFailure("local shelf slider missing: \(count), \(library.error)")
            }
            @MainActor func checkPage(count:Int) async{
                let control=await slider(count:count)
                guard let scroll=views().compactMap({$0 as? UIScrollView}).first(where:{$0.contentSize.height>$0.bounds.height+100}) else{preconditionFailure("shelf scroll missing")}
                let page=library.pageIndex,ids=library.books.map(\.id),requests=ReaderDemo.requests["shelf-list"]
                let start=scroll.contentOffset.y
                control.begin(at:CGPoint(x:37,y:control.bounds.height))
                precondition(scroll.contentOffset.y==start,"preview must not scroll or load")
                control.finish(cancelled:false);await settled()
                precondition(scroll.contentOffset.y+scroll.bounds.height>=scroll.contentSize.height-80,"bottom target not visible")
                precondition(control.value==count-1,"bottom rail must reach current-page endpoint: \(control.value) / \(count)")
                let bottom=scroll.contentOffset.y
                control.begin(at:CGPoint(x:37,y:control.bounds.height/2));control.finish(cancelled:false);await settled()
                precondition(scroll.contentOffset.y<bottom-100 && control.value>0 && control.value<count-1,"middle seek")
                control.begin(at:CGPoint(x:37,y:0));control.finish(cancelled:false);await settled()
                precondition(control.value<3 && scroll.contentOffset.y<600,"return to local first row")
                precondition(library.pageIndex==page && library.books.map(\.id)==ids && ReaderDemo.requests["shelf-list"]==requests,"rail must not cross page, reorder, or request catalog")
                control.layoutIfNeeded()
                precondition(!control.point(inside:CGPoint(x:1,y:control.bounds.height-20),with:nil),"empty overlay must pass cover taps through")
                precondition(control.point(inside:CGPoint(x:37,y:control.bounds.height-20),with:nil),"edge track remains tappable")
                print("PASS local \(count)-book rail: endpoints, middle, no catalog requests/order changes, hit testing")
            }
            await checkPage(count:500)
            await library.loadPage(20);await checkPage(count:71)
            library.pageSize=50
            _=await slider(count:50);await checkPage(count:50)
            await library.loadPage(201);await checkPage(count:21)
            print("4 current-page shelf integration scenarios passed");exit(0)
        }
    }}
}
#endif
