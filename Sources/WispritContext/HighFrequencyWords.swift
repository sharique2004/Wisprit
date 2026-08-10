import Foundation

/// The compiled-in floor under every lexicon: ~600 words that must ALWAYS read
/// as ordinary, even before `/usr/share/dict/words` finishes loading and even
/// on a machine that lacks it.
///
/// Three deliberate slices, each answering a failure the research documented:
///  * high-frequency English (including inflections the system word list
///    lacks — it has "deploy" but not "deploys"),
///  * workplace vocabulary — the exact "sprint"/"deploy"/"standup" class Wispr
///    Flow's ungated auto-add kept learning as if they were proper nouns,
///  * Swift/JS keywords and everyday dev nouns, because dictated speech in
///    this codebase's own dogfood is full of them and none is worth biasing.
public enum HighFrequencyWords {

    public static let words: Set<String> =
        Set(raw.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let raw = """
    a about above account across action actually add added address after again against age agenda ago
    agree air all almost along already also although always am among amount an and another answer any
    anyone anything api app apps architecture are area around art as ask asked at away
    baby back backend backlog bad balance ball bank battery be became because become been before began
    begin behind being believe below best better between big bit black blue board body book both box
    boy branch break bring brought browser bug bugs build builds built business but button buy by
    cache calendar call called came can cancel cannot car card care case catch caught center chance
    change changed channel chat check child children chip choose chose city class clean clear client
    close cloud code coding coffee cold college color come coming commit committed company compile
    compiler component config configuration console consider contact continue copy cost could country
    couple course cover crash create created cut dark dashboard data database date day days dead deal
    deadline dear debug decide decided deep default delete demo dependencies dependency deploy deployed
    deployment deploys design desk desktop detail dev developer development device did different dinner
    do docs document documentation does doing done door down download draft dream dress drink drive
    during each early easy eat edit editor either else email end endpoint engineer engineering enough
    error errors estimate even evening event ever every everyone everything example expect explain eye
    face fact fair fall family far fast father feature features feedback feel felt few field figure
    file fill find fine finish fire first fix fixes floor folder follow followup food foot for form
    found four framework free friend friends from front frontend full fun funny future game gave get
    girl give given glad go goal goals goes going gold gone good got gray great green ground group
    grow guess guy had hair half hand happen happened happy hard has have having he head hear heard
    heart heavy held hello help her here high him his history hit hold home hope hot hotfix hour hours
    house how however human hundred husband i ice icon idea if image important in inbox include
    including information inside install instead internet into invite is issue it item its job join
    just keep kept key kickoff kids kind knew know known land language laptop large last late later
    laugh launch lead learn least leave led left less let library life light like line link list
    little live local login logout logs long look looked looking lose lost lot love low lunch machine
    made mail main make making man manager many map market matter may maybe me mean meant meeting
    meetings men mention merge merged message met metric metrics middle might mile milestone milk
    million mind minute miss mobile mockup module moment mom money monitor month more morning most
    mother mouth move moved movie much music must my name near need network never new next nice night
    no north not note notes nothing now number of off offer office offline offsite often okay old on
    onboarding once one online only open or orange order other others our out over own page paid paper
    parent park part party pass password past patch pay people performance perhaps person phone photo
    pick picture piece ping pipeline place plan plane planning platform play played player please
    point police poor port power pretty price problem process product production project prompt
    provide public pull push pushed put quarter question queue quick quiet quite race radio rain
    rather reach read ready readme real really reason receive record red refactor release remain
    remember remote remove repo report reports request require research response rest result retro
    retrospective return review reviews rich ride right river road roadmap rock role rollback rollout
    room rule run runtime sad safe said sale salt same save saw say saying schedule school scope
    screen script scripts sea search season seat second see seem seemed seen sell send sense sent
    serve server service settings setup seven share she ship shipped shop short should show showed
    side sign signup simple since single sister sit site six size sky sleep slide slides slow small
    snake snow so social soft software some someone something sometimes song soon sorry sound south
    space speak spec specs spend spent sport spreadsheet spring sprint sprints staging stakeholder
    stand standup star start started startup state status stay step still stood stop storage store
    story street strong student study stuff style such summer sun sure sweet sync system table take
    taken talk task tasks teach teacher team teammate tell template ten term terminal test text than
    thank thanks that the their them then there these they thing things think third this those though
    thought thread three through throw ticket tickets time timeline timezone tiny tired to today
    together told too took top total touch toward town track trade train travel treat tried trip true
    truth try turn turned two type under understand unit until up update updates upgrade upload upon
    us use used user users using value variable vendor version very video view visit voice wait walk
    wall want wanted warm was watch water way we weather web website week well went were west what
    when where whether which while white who whole why wide widget wife will win window winter wish
    with within without woman women wonder wood word words work worked workflow working workspace
    world worry would write wrong wrote year years yellow yes yesterday yet you young your
    actor any array associatedtype async await bool boolean borrowing catch class closure const
    constant continue convenience deinit defer dictionary didset do double else enum export extends
    extension fallthrough false fileprivate final finally float for func function get guard if
    implements import in indirect infer init inout instanceof int interface internal isolated lazy
    let map mutating new nil nonisolated null number object optional override private promise
    protocol repeat required rethrows return self set some static string struct subscript super
    switch this throws try typealias typeof undefined unowned var void weak where willset yield
    """
}
