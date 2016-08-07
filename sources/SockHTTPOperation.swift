
// Copyright (c) NagisaWorks asaday
// The MIT License (MIT)

import Foundation
import GCDAsyncSocket

class SockHTTPOperation: NSOperation, GCDAsyncSocketDelegate {

	var request: NSURLRequest
	let completion: (NSData?, NSURLResponse?, NSError?) -> Void

	var socket: GCDAsyncSocket?
	var url: NSURL = NSURL()
	var response: NSHTTPURLResponse!
	var redirectCount: Int = 0

	var rehttpsSession: NSURLSession?
	var rehttpsTask: NSURLSessionDataTask?

	class func isATSBlocked(url: NSURL?) -> Bool {
		guard let url = url else { return false }
		if url.scheme != "http" { return false }

		guard let dic = NSBundle.mainBundle().objectForInfoDictionaryKey("NSAppTransportSecurity") as? [String: AnyObject] else { return true }

		if dic["NSAllowsArbitraryLoads"] as? Bool ?? false { return false }
		guard let domains = dic["NSExceptionDomains"] as? [String: AnyObject] else { return true }
		for (k, v) in domains {
			if k != url.host { continue }
			guard let dkv = v as? [String: AnyObject] else { continue }
			if dkv["NSExceptionAllowsInsecureHTTPLoads"] as? Bool ?? false { return false }
		}
		return true
	}

	static let dqueue = dispatch_queue_create("com.nagisa.httpopration", nil)

	init(request: NSURLRequest, completion: (NSData?, NSURLResponse?, NSError?) -> Void) {
		self.request = request
		self.completion = completion
		super.init()
	}

	override var asynchronous: Bool {
		return true
	}

	private var _executing: Bool = false
	override var executing: Bool {
		get { return _executing }
		set {
			willChangeValueForKey("isExecuting")
			_executing = newValue
			didChangeValueForKey("isExecuting")
		}
	}

	private var _finished: Bool = false
	override var finished: Bool {
		get { return _finished }
		set {
			willChangeValueForKey("isFinished")
			_finished = newValue
			didChangeValueForKey("isFinished")
		}
	}

	override func cancel() {
		socket?.disconnect()
		socket = nil
		rehttpsTask?.cancel()
		super.cancel()
	}

	override func start() {
		if cancelled {
			finished = true
			return
		}
		guard let u = request.URL, _ = request.HTTPMethod else {
			let error = NSError(domain: "http", code: 1, userInfo: [NSLocalizedDescriptionKey: ""])
			completion(nil, nil, error)
			finished = true
			return
		}
		url = u

		executing = true
		main()
	}

	override func main() {
		if cancelled {
			done()
			return
		}

		guard let host = url.host, _ = url.path else {
			compError(2, msg: "")
			return
		}

		socket = GCDAsyncSocket(delegate: self, delegateQueue: SockHTTPOperation.dqueue)

		do {
			try socket?.connectToHost(host, onPort: UInt16(url.port?.intValue ?? 80), withTimeout: request.timeoutInterval)
		} catch let e as NSError {
			compError(e)
			return
		}

	}

	func socketDidDisconnect(sock: GCDAsyncSocket, withError err: NSError?) {
		if let e = err { compError(e) }
	}

	func socket(sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {

		var headlines: [String] = []
		var path = url.path ?? ""
		if let q = url.query { path += "?" + q }
		headlines.append("\(request.HTTPMethod!) \(path) HTTP/1.1")
		headlines.append("Host: \(url.host ?? "")")

		let agent = (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleName") as? String ?? "") + "/" +
			(NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") as? String ?? "") + " EzHTTP/1"

		var headers: [String: String] = ["Accept": "*/*", "User-Agent": agent]
		if let reqheaders = request.allHTTPHeaderFields {
			for (k, v) in reqheaders { headers[k] = v }
		}
		if let cookies = NSHTTPCookieStorage.sharedHTTPCookieStorage().cookiesForURL(url) {
			let cheaders = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies)
			for (k, v) in cheaders { headers[k] = v }
		}

		if let d = request.HTTPBody { headers["Content-Length"] = "\(d.length)" }

		headlines.appendContentsOf(headers.map { "\($0): \($1)" })
		headlines.append("")
		headlines.append("")

		let dat: NSMutableData = headlines.joinWithSeparator("\r\n").dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: true) as! NSMutableData

		if let d = request.HTTPBody { dat.appendData(d) }

		socket?.writeData(dat, withTimeout: request.timeoutInterval, tag: 0)
		socket?.readDataToData("\r\n\r\n".dataUsingEncoding(NSUTF8StringEncoding)!, withTimeout: request.timeoutInterval, tag: 0)
	}

	func socket(sock: GCDAsyncSocket, didReadData data: NSData, withTag tag: Int) {
		if cancelled {
			done()
			return
		}

		if response == nil {
			guard let r = makeResponse(data) else {
				compError(3, msg: "")
				return
			}

			if r.statusCode >= 301 && r.statusCode <= 308 {
				if redirectCount > 10 {
					compError(3, msg: "")
					return
				}

				if let location = r.allHeaderFields["Location"] as? String {
					socket?.disconnect()
					socket = nil
					url = NSURL(string: location, relativeToURL: url) ?? url
					if url.scheme == "https" {
						if let nreq = request.mutableCopy() as? NSMutableURLRequest {
							nreq.URL = url
							rehttpsTask = rehttpsSession?.requestData(nreq, { (d, r, e) in
								if !self.cancelled { self.completion(d, r, e) }
								self.done()
							})
							return
						}
					}
				}
				main()
				return
			}

			response = r
			guard let lenstr = response.allHeaderFields["Content-Length"] as? String, len = UInt(lenstr) else {
				compError(4, msg: "")
				return
			}

			socket?.readDataToLength(len, withTimeout: request.timeoutInterval, tag: 0)
		} else {
			completion(data, response, nil)
			done()
		}
	}

	func makeResponse(data: NSData) -> NSHTTPURLResponse? {
		guard let hs = String(data: data, encoding: NSUTF8StringEncoding) else { return nil }
		var headlines = hs.componentsSeparatedByString("\r\n")

		let st = headlines[0].componentsSeparatedByString(" ")
		if st.count <= 2 { return nil }
		guard let status = Int(st[1]) else { return nil }

		headlines.removeFirst()
		var headers: [String: String] = [:]

		for h in headlines {
			guard let ra = h.rangeOfString(":") else { continue }

			let k = h.substringToIndex(ra.startIndex).stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet())
			let v = h.substringFromIndex(ra.endIndex).stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet())

			if k == "Set-Cookie" {
				let cookies = NSHTTPCookie.cookiesWithResponseHeaderFields([k: v], forURL: url)
				NSHTTPCookieStorage.sharedHTTPCookieStorage().setCookies(cookies, forURL: url, mainDocumentURL: url)
				continue
			}
			headers[k] = v
		}

		return NSHTTPURLResponse(URL: url, statusCode: status, HTTPVersion: st[0], headerFields: headers)
	}

	func done() {
		socket?.disconnect()
		socket = nil
		executing = false
		finished = true
	}

	func compError(error: NSError) {
		completion(nil, nil, error)
		done()
	}

	func compError(code: Int, msg: String) {
		let error = NSError(domain: "http", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
		compError(error)
	}

}
