import Foundation

// MARK: - Терпимый разбор JSON

/// Значение по умолчанию для поля, которого нет в ответе (или оно null, или другого типа).
protocol Defaultable { static var defaultValue: Self { get } }
extension Array: Defaultable { static var defaultValue: Self { [] } }
extension String: Defaultable { static var defaultValue: String { "" } }
extension Bool: Defaultable { static var defaultValue: Bool { false } }
extension Int: Defaultable { static var defaultValue: Int { 0 } }
extension Dictionary: Defaultable { static var defaultValue: Self { [:] } }

/// Поле со значением по умолчанию: сервер разных версий отдаёт разный набор полей,
/// а падение разбора из‑за одного отсутствующего ключа — это пустой экран.
@propertyWrapper
struct D<T: Codable & Sendable & Hashable & Defaultable>: Codable, Sendable, Hashable {
    var wrappedValue: T
    init(wrappedValue: T = T.defaultValue) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = (try? c.decode(T.self)) ?? T.defaultValue
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: D<T>.Type, forKey key: Key) throws -> D<T> {
        try decodeIfPresent(type, forKey: key) ?? D()
    }
}

/// Произвольное значение JSON — настраиваемые поля бывают строкой, массивом строк или null.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Значения строками: одиночное — 0..1 элемент, массив — сколько выбрано.
    var strings: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .number(let n): return [n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)]
        case .bool(let b): return [b ? "1" : "0"]
        case .array(let a): return a.flatMap(\.strings).filter { !$0.isEmpty }
        default: return []
        }
    }

    var isArray: Bool { if case .array = self { return true } else { return false } }

    var display: String { strings.joined(separator: ", ") }
}

// MARK: - Модели Redmine

struct Named: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    init(id: Int, name: String = "") { self.id = id; self.name = name }
}

struct IssueStatus: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isClosed: Bool
}

struct Priority: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isDefault: Bool
    var active: Bool?
}

struct Tracker: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
}

struct Project: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var identifier: String
    var description: String?
    var parent: Named?
    var status: Int?
    @D var trackers: [Tracker]
    @D var issueCustomFields: [Named]
    init(id: Int, name: String = "") { self.id = id; self.name = name }
}

struct Version: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    var status: String?
    var dueDate: String?
}

struct CustomField: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    var value: JSONValue?
    @D var multiple: Bool
    var values: [String] { value?.strings ?? [] }
}

struct CustomFieldOption: Codable, Sendable, Hashable {
    @D var value: String
    @D var label: String
}

/// Описание настраиваемого поля из /custom_fields.json (не-админу обычно 403).
struct CustomFieldDef: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var customizedType: String
    @D var fieldFormat: String
    @D var isRequired: Bool
    @D var multiple: Bool
    @D var possibleValues: [CustomFieldOption]
    var defaultValue: String?
    @D var trackers: [Named]
}

struct JournalDetail: Codable, Sendable, Hashable {
    @D var property: String
    @D var name: String
    var oldValue: String?
    var newValue: String?
}

struct Journal: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var user: Named?
    var notes: String?
    @D var createdOn: String
    var updatedOn: String?
    @D var privateNotes: Bool
    @D var details: [JournalDetail]
}

struct Attachment: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var filename: String
    @D var filesize: Int
    var contentType: String?
    @D var contentUrl: String
    var author: Named?
    @D var createdOn: String
    var description: String?
    var thumbnailUrl: String?

    var isImage: Bool {
        if let t = contentType, t.hasPrefix("image/") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(ext)
    }
}

struct ChildIssue: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var tracker: Named?
    @D var subject: String
}

struct Relation: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var issueId: Int
    var issueToId: Int
    @D var relationType: String
    var delay: Int?
}

struct IDRef: Codable, Sendable, Hashable { var id: Int }

struct Issue: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var project: Named
    var tracker: Named
    var status: IssueStatus
    var priority: Named
    var author: Named
    var assignedTo: Named?
    var category: Named?
    var fixedVersion: Named?
    var parent: IDRef?
    @D var subject: String
    var description: String?
    var startDate: String?
    var dueDate: String?
    @D var doneRatio: Int
    @D var isPrivate: Bool
    var estimatedHours: Double?
    var totalEstimatedHours: Double?
    var spentHours: Double?
    var totalSpentHours: Double?
    @D var customFields: [CustomField]
    @D var createdOn: String
    @D var updatedOn: String
    var closedOn: String?
    @D var journals: [Journal]
    @D var attachments: [Attachment]
    @D var children: [ChildIssue]
    @D var relations: [Relation]
    @D var watchers: [Named]
    var allowedStatuses: [IssueStatus]?
}

struct User: Codable, Sendable, Hashable {
    var id: Int
    @D var login: String
    @D var firstname: String
    @D var lastname: String
    var mail: String?
    var apiKey: String?
    @D var admin: Bool
    var displayName: String {
        let n = [firstname, lastname].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? login : n
    }
}

struct Membership: Codable, Sendable, Hashable {
    var id: Int
    var user: Named?
    var group: Named?
    @D var roles: [Named]
    var project: Named?
}

/// Мои роли в компактном виде для кэша: проект → id ролей (сырой ответ — больше мегабайта).
struct MyRoles: Codable, Sendable, Hashable {
    var admin: Bool
    var roles: [Int: [Int]]
}

struct Role: Codable, Sendable, Hashable { @D var id: Int; @D var name: String; @D var permissions: [String] }

struct TimeEntryActivity: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isDefault: Bool
    var active: Bool?
}

struct TimeEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var user: Named?
    var activity: Named?
    var hours: Double?
    @D var comments: String
    @D var spentOn: String
    var project: Named?
    var issue: IDRef?
    @D var createdOn: String
}

/// Загруженный файл: токен для вложения к задаче/комментарию.
struct UploadRef: Sendable, Hashable {
    var token: String
    var filename: String
    var contentType: String?
    var description: String?
}

/// Профиль: плагин People (должность/отдел), иначе /users. Имена полей на разных серверах разные.
struct Person: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var login: String?
    var email: String?
    var mail: String?
    @D var firstname: String
    var middlename: String?
    @D var lastname: String
    var firstName: String?
    var lastName: String?
    var jobTitle: String?
    var department: Named?
    var personnelNumber: String?
    var managerId: Int?

    init(id: Int, login: String? = nil, firstname: String = "", lastname: String = "") {
        self.id = id; self.login = login; self.firstname = firstname; self.lastname = lastname
    }

    var first: String { firstname.isEmpty ? (firstName ?? "") : firstname }
    var last: String { lastname.isEmpty ? (lastName ?? "") : lastname }
    var mailAddr: String? { email ?? mail }
    var displayName: String { [first, middlename ?? "", last].filter { !$0.isEmpty }.joined(separator: " ") }
    /// «Имя Фамилия» — для упоминаний, без отчества.
    var shortName: String { [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var title: String
    @D var type: String
    @D var url: String
    @D var description: String
    @D var datetime: String
}

// MARK: - Конверты ответов

struct IssuesResponse: Codable, Sendable { @D var issues: [Issue]; @D var totalCount: Int }
struct IssueResponse: Codable, Sendable { var issue: Issue }
struct AttachmentResponse: Codable, Sendable { var attachment: Attachment }
struct ProjectsResponse: Codable, Sendable { @D var projects: [Project]; @D var totalCount: Int }
struct ProjectResponse: Codable, Sendable { var project: Project }
struct UserResponse: Codable, Sendable { var user: User }
struct StatusesResponse: Codable, Sendable { @D var issueStatuses: [IssueStatus] }
struct PrioritiesResponse: Codable, Sendable { @D var issuePriorities: [Priority] }
struct TrackersResponse: Codable, Sendable { @D var trackers: [Tracker] }
struct VersionsResponse: Codable, Sendable { @D var versions: [Version] }
struct MembershipsResponse: Codable, Sendable { @D var memberships: [Membership]; @D var totalCount: Int }
struct ActivitiesResponse: Codable, Sendable { @D var timeEntryActivities: [TimeEntryActivity] }
struct TimeEntriesResponse: Codable, Sendable { @D var timeEntries: [TimeEntry]; @D var totalCount: Int }
struct SearchResponse: Codable, Sendable { @D var results: [SearchResult]; @D var totalCount: Int }
struct CategoriesResponse: Codable, Sendable { @D var issueCategories: [Named] }
struct CustomFieldsResponse: Codable, Sendable { @D var customFields: [CustomFieldDef] }
struct ErrorsResponse: Codable, Sendable { @D var errors: [String] }
struct RoleResponse: Codable, Sendable { var role: Role }
struct PeopleResponse: Codable, Sendable { var person: Person }
struct PeopleListResponse: Codable, Sendable { @D var people: [Person] }
struct MeWithMemberships: Codable, Sendable { @D var admin: Bool; @D var memberships: [Membership] }
struct MeWithMembershipsResponse: Codable, Sendable { var user: MeWithMemberships }
struct UploadResponse: Codable, Sendable { struct U: Codable, Sendable { var token: String }; var upload: U }

// MARK: - Общий JSON

enum JSON {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

extension Tracker { init(id: Int, name: String) { self.id = id; self.name = name } }
extension Priority { init(id: Int, name: String) { self.id = id; self.name = name } }
