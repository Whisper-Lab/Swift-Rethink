import Foundation

public typealias ReDocument = [String: AnyObject]

public class ReDatum: ReQueryValue {
	public let jsonSerialization: AnyObject
	private static let reqlTypeTime = "TIME"
	private static let reqlTypeBinary = "BINARY"
	private static let reqlSpecialKey = "$reql_type$"

	internal init() {
		self.jsonSerialization = NSNull()
	}

	internal init(string: String) {
		self.jsonSerialization = string
	}

	internal init(double: Double) {
		self.jsonSerialization = double
	}

	internal init(int: Int) {
		self.jsonSerialization = int
	}

	internal init(bool: Bool) {
		self.jsonSerialization = bool
	}

	internal init(array: [ReQueryValue]) {
		self.jsonSerialization = [ReTerm.MAKE_ARRAY.rawValue, array.map { return $0.jsonSerialization }]
	}

	internal init(document: ReDocument) {
		self.jsonSerialization = document
	}

	internal init(object: [String: ReQueryValue]) {
		var serialized: [String: AnyObject] = [:]
		for (key, value) in object {
			serialized[key] = value.jsonSerialization
		}
		self.jsonSerialization = serialized
	}

	internal init(date: NSDate) {
		self.jsonSerialization = [ReDatum.reqlSpecialKey: ReDatum.reqlTypeTime, "epoch_time": date.timeIntervalSince1970, "timezone": "+00:00"]
	}

	internal init(data: NSData) {
		self.jsonSerialization = [ReDatum.reqlSpecialKey: ReDatum.reqlTypeBinary, "data": data.base64EncodedStringWithOptions([])]
	}

	internal init(jsonSerialization: AnyObject) {
		self.jsonSerialization = jsonSerialization
	}

	internal var value: AnyObject { get {
		if let d = self.jsonSerialization as? [String: AnyObject], let t = d[ReDatum.reqlSpecialKey] as? String {
			if t == ReDatum.reqlTypeBinary {
				if let data = self.jsonSerialization.valueForKey("data") as? String {
					return NSData(base64EncodedString: data, options: [])!
				}
				else {
					fatalError("invalid binary datum received")
				}
			}
			else if t == ReDatum.reqlTypeTime {
				if let epochTime = self.jsonSerialization.valueForKey("epoch_time"), let timezone = self.jsonSerialization.valueForKey("timezone") as? String {
					// TODO: interpret server timezone other than +00:00 (UTC)
					assert(timezone == "+00:00", "support for timezones other than UTC not implemented (yet)")
					return NSDate(timeIntervalSince1970: epochTime.doubleValue!)
				}
				else {
					fatalError("invalid date received")
				}
			}
			else {
				fatalError("unrecognized $reql_type$ in serialized data")
			}
		}
		else {
			return self.jsonSerialization
		}
	} }
}
