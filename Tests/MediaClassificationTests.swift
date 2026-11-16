import Foundation

@main struct MediaClassificationTests {
    static func main() throws {
        let fm=FileManager.default
        let home=URL(fileURLWithPath:"/Users/Shared/qingsweep-mediakind-"+UUID().uuidString)
        defer { try? fm.removeItem(at:home) }
        let classifier=FileClassifier(policy:SafetyPolicy(home:home),context:InspectionContext())
        var count=0
        func check(_ value:Bool,_ title:String) {guard value else {fputs("FAIL: "+title+"\n",stderr);exit(1)};count += 1;print("PASS: "+title)}
        @discardableResult func file(_ path:String,_ category:FileCategory)throws->FileAssessment {
            let u=home.appendingPathComponent(path);try fm.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(repeating:42,count:8192).write(to:u)
            let a=classifier.assess(u,stamp:FileStamp.read(u)!)
            check(a.category==category,"known purpose: "+path)
            check(a.requiresIndividualConfirmation && !a.canBatchSelect,"manual confirmation retained: "+path)
            return a
        }
        try file("Downloads/Demo-footage.mov",.video)
        try file("Downloads/素材/Clip.mp4",.video)
        try file("Downloads/filmforever/Clip.MOV",.video)
        try file("Downloads/preset-photo.arw",.photo)
        try file("Downloads/预设音频.wav",.audio)
        try file("Downloads/Color.cube",.preset)
        try file("Downloads/Footage-Pack.zip",.preset)
        try file("Downloads/Tropic Colour.dmg",.preset)
        try file("Downloads/FootageProject.drp",.project)
        try file("Library/Caches/pip/wheels/Footage.mov",.video)
        let proxy=try file("Movies/ProxyMedia/Footage.mov",.video)
        check(proxy.ruleID=="resolve-proxy" && proxy.needsClosedApps && proxy.blockingAppIDs.contains("com.blackmagic-design.DaVinciResolve"),"a named-footage proxy retains Resolve application checks")
        try fm.createDirectory(at:home.appendingPathComponent("Documents/Edit/.git"),withIntermediateDirectories:true)
        try file("Documents/Edit/Footage.mov",.project)
        print("\(count) media-classification checks passed; generated files only")
    }
}
