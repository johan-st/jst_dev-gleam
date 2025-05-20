# who

auth n auth

## Claude says

This test file includes:

1. A golden file testing approach where test results can be compared against expected outcomes stored in a JSON file
2. A flag `-update` that can be used to update the golden file when needed
3. Two test functions:
   - `TestWhoPermissions`: Runs tests and compares against a golden file
   - `TestMoreComprehensivePermissions`: A more detailed test with specific assertions

To run the tests and update the golden file:
```
go test -v ./server/who -update
```

To run the tests against the existing golden file:
```
go test -v ./server/who
```

Note that you'll need to create a `testdata` directory in your `who` package directory for the golden files. The test cases should be expanded to cover all the permission scenarios defined in your Prolog rules.
