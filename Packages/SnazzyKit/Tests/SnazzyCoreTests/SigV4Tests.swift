import Foundation
import Testing
@testable import SnazzyCore

/// Vectors from AWS's S3 Signature Version 4 documentation.
@Suite struct SigV4Tests {
    let signer = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
    let date = Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24T00:00:00Z

    @Test func presignedURLMatchesAWSExample() {
        let url = signer.presignedURL(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86_400, date: date)
        #expect(url.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
        #expect(url.absoluteString.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"))
    }

    @Test func headerSigningMatchesAWSGetObjectExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, payloadHash: SigV4.emptyPayloadHash, date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func encodingRules() {
        #expect(SigV4.encode("a b/c~d") == "a%20b%2Fc~d")
        #expect(SigV4.canonicalPath(URL(string: "https://h/bucket/my%20file%20(trimmed).mp4")!) == "/bucket/my%20file%20%28trimmed%29.mp4")
        #expect(SigV4.hostHeader(URL(string: "http://localhost:9000/x")!) == "localhost:9000")
    }
}
