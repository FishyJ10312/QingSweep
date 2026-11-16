import AppKit
import Foundation

@main struct LocalizationTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil);_ = NSApplication.shared
        let catalog=try TranslationCatalog(url:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Translations.json"))
        var count=0
        func check(_ value:@autoclosure ()->Bool,_ title:String){guard value() else{fputs("FAIL: "+title+"\n",stderr);exit(1)};count += 1;print("PASS: "+title)}
        check(InterfaceLanguage.resolve(preferredLanguages:["en-AU"]) == .english,"English system language resolves to English")
        check(InterfaceLanguage.resolve(preferredLanguages:["zh-Hans-AU","en-AU"]) == .chinese,"Chinese system language resolves to Chinese")
        check(InterfaceLanguage.resolve(preferredLanguages:["ja-JP"]) == .english,"unsupported system languages use English")
        check(catalog.text("推荐清理",language:.english)=="Recommended","recommended cleanup has an English label")
        check(catalog.text("需自行确认",language:.english)=="Manual review","manual review remains distinct from recommendations")
        check(catalog.text("素材和项目默认不选，手动选择后需二次确认",language:.english)=="Media and projects start unselected. Manual selection requires a second confirmation.","English safety copy preserves the selection and confirmation rules")
        check(catalog.text("1 项",language:.english)=="1 item","singular item count is grammatical")
        check(catalog.text("2 项",language:.english)=="2 items","plural item count is grammatical")
        check(catalog.text("121 项",language:.english)=="121 items","counts ending in 1 are not accidentally singularized")
        check(catalog.text("正在退出 1 items.mov…",language:.english)=="Quitting 1 items.mov…","interpolated file-like values are not changed by pluralization")
        check(catalog.text("正在退出 清理…",language:.english)=="Quitting 清理…","interpolated application names remain verbatim")
        let path="/Users/Example/我的项目/1 items.mov"
        check(catalog.text("无法读取："+path,language:.english)=="Cannot read: "+path,"absolute paths with Chinese names and spaces remain verbatim")
        check(catalog.error("清理：文件在扫描后发生变化，请重新扫描。",language:.english)=="清理: The file changed after scanning. Scan again.","an error prefix that equals an interface label remains a filename")
        check(catalog.text("推荐清理",language:.chinese)=="推荐清理","Chinese text is returned without modification")
        check(catalog.text("常用位置 · 扫描完成",language:.english)=="Common locations · Scan complete","completed first-use scan status uses a readable English sentence")
        let marker=try NSRegularExpression(pattern:#"\{([0-9]+)\}"#)
        var covered=0
        for entry in catalog.entries {
            let n=entry.source as NSString;let matches=marker.matches(in:entry.source,range:NSRange(location:0,length:n.length))
            var source=entry.source,expected=entry.english
            for i in Set(matches.map{n.substring(with:$0.range(at:1))}) {
                source=source.replacingOccurrences(of:"{"+i+"}",with:"17")
                expected=expected.replacingOccurrences(of:"{"+i+"}",with:"17")
            }
            let actual=catalog.text(source,language:.english)
            guard actual==expected else{fputs("FAIL catalogue: "+entry.source+" => "+actual+"; expected "+expected+"\n",stderr);exit(1)}
            covered += 1
        }
        check(covered>=780,"all catalogue messages and interpolations render the reviewed English text")
        let evidence="已 17 天未修改；时间只能说明较旧，不能证明不再需要。 仅匹配 pip 缓存结构，不包含已安装环境。"
        let localized=catalog.text(evidence,language:.english)
        check(localized.range(of:#"\p{Han}"#,options:.regularExpression)==nil,"composed classification evidence is fully translated")
        check(catalog.text("1 项 · 1.1 MB",language:.english)=="1 item · 1.1 MB","composed impact counts translate and pluralize without changing byte values")
        check(catalog.text("1.1 MB · 2 项",language:.english)=="1.1 MB · 2 items","composed media rows translate their count suffix")
        let namespace="QingSweep.LocalizationTests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:namespace)!;defer{defaults.removePersistentDomain(forName:namespace)}
        let settings=LanguageSettings(defaults:defaults);settings.choice = .english
        check(LanguageSettings(defaults:defaults).choice == .english,"language preference survives relaunch in an isolated preferences domain")
        // UI language must not alter Codable/raw identifiers or weaken manual cleanup.
        let fm=FileManager.default,home=URL(fileURLWithPath:"/Users/Shared/qingsweep-i18n-"+UUID().uuidString)
        try fm.createDirectory(at:home,withIntermediateDirectories:true);defer{try? fm.removeItem(at:home)}
        let a=home.appendingPathComponent("推荐清理.mov"),b=home.appendingPathComponent("需自行确认.drp")
        try Data(repeating:42,count:8192).write(to:a);try Data(repeating:43,count:8192).write(to:b)
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false)
        let classifier=FileClassifier(policy:model.policy,context:InspectionContext())
        let items=[a,b].map{url in let stamp=FileStamp.read(url)!;return ScanItem(url:url,root:home,stamp:stamp,assessment:classifier.assess(url,stamp:stamp))}
        model.items=items
        check(model.selected.isEmpty,"media and projects start unselected with localization enabled")
        model.selectPriority()
        check(model.selected.isEmpty,"recommendations still exclude media and projects")
        let data=try JSONEncoder().encode(items),roundtrip=try JSONDecoder().decode([ScanItem].self,from:data)
        check(roundtrip.map(\.assessment)==items.map(\.assessment) && FileCategory.project.rawValue=="项目与源代码","persisted classification identifiers remain compatible")
        check(roundtrip.map{ $0.url.lastPathComponent }==["推荐清理.mov","需自行确认.drp"],"file names matching interface vocabulary survive unchanged")
        let scope=home.appendingPathComponent("StorageFixture");try fm.createDirectory(at:scope,withIntermediateDirectories:true)
        let original=scope.appendingPathComponent("原始项目.dat");try Data(repeating:91,count:8192).write(to:original)
        let db=home.appendingPathComponent("index.sqlite"),root=StorageRoot(url:scope,title:"文稿与项目",kind:.project)
        _=try StorageIndex.build(at:db,roots:[root],auditor:StorageAuditor(home:home),applications:[],cancellation:ScanCancellation())
        let aliases=catalog.sourceTitles(matchingEnglish:"projects",language:.english)
        let index=try StorageIndex(url:db),page=try index.page(search:"projects",searchOwnerTitles:aliases)
        check(page.items.contains{$0.url==original},"English owner-title searches find older Chinese-indexed metadata")
        check(page.items.first{$0.url==original}?.title=="原始项目.dat","English search never changes stored file names")
        let other=try index.page(ownerID:"personal:elsewhere",search:"projects",searchOwnerTitles:aliases)
        check(other.total==0,"localized search aliases preserve application scope filtering")
        print("\(count) localization checks passed; \(covered) catalogue entries checked")
    }
}
