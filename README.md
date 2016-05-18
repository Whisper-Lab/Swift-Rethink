Swift-Rethink
-------------

A client driver for RethinkDB in Swift.

## Prerequisites

### Swift
* Swift Open Source `swift-DEVELOPMENT-SNAPSHOT-2016-04-25-a` toolchain (**Minimum REQUIRED for latest release**)
* Swift Open Source `swift-DEVELOPMENT-SNAPSHOT-2016-05-03-a` toolchain (**Recommended**)

### OS X

* OS X 10.11.0 (*El Capitan*) or higher
* Xcode Version 7.3.1 (7D1012) or higher using the one of the above toolchains (*Recommended*)

### Linux

* Ubuntu 15.10 (or 14.04)
* One of the Swift Open Source toolchains listed above

## Build

To build Rethink from the command line:

```
% cd <path-to-clone>
% swift build
```

## Using Swift-Rethink

### Before starting

The first you need to do is import the Rethink framework.  This is done by the following:
```
import Rethink
```

### Example

```swift
self.connection = R.connect(NSURL(string: "rethinkdb://localhost:28016")!, user: "admin", password: "") { err in
	assert(err == nil, "Connection error: \(err)")

	// Connected!
	R.dbCreate(databaseName).run(connection) { response in
		assert(!response.isError, "Failed to create database: \(response)")

		R.db(databaseName).tableCreate(tableName).run(self.connection) { response in
			assert(!response.isError, "Failed to create table: \(response)")

			R.db(databaseName).table(tableName).indexWait().run(self.connection) { response in
				assert(!response.isError, "Failed to wait for index: \(response)")

				// Insert 1000 documents
				var docs: [ReDocument] = []
				for i in 0..<1000 {
					docs.append(["foo": "bar", "id": i])
				}

				R.db(databaseName).table(tableName).insert(docs).run(self.connection) { response in
					assert(!response.isError, "Failed to insert data: \(response)")

					R.db(databaseName).table(tableName).filter({ r in return r["foo"].eq(R.expr("bar")) }).run(self.connection) { response in 
						...
					}

					R.db(databaseName).table(tableName).count().run(self.connection) { response in
						...
					}
				}
			}
		}
	}
}
```

### Status

The driver implements the V1_0 protocol (which supports username/password authentication using SCRAM, and is available 
from RethinkDB 2.3.0). Alternatively, you can also use V0_4. Some commands and optional arguments may still be missing,
but are usually easy to add to the code.
