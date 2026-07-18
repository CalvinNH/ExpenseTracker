# Implementation Plan: Notification Transaction Parser & Bug Fixes

This implementation plan details the steps required to build a robust Regular Expression (Regex) parser for banking and UPI notifications, connect the notification listener service to the SQLite database, keep account balances dynamically updated, and resolve multiple bugs in the codebase.

## User Review Required

> [!IMPORTANT]
> **Pub Package Dependency Correction**: The `pubspec.yaml` specifies `notification_listener_service: ^3.2.0`, which does not exist. The actual latest version is `^1.0.0` (as verified in the local pub cache metadata). We will downgrade this constraint to `^1.0.0` to allow the package manager to resolve dependencies and build successfully.

> [!NOTE]
> **Account Balance Sync**: We are adding automatic balance synchronization in `AppDatabase` so that when transaction CRUD operations occur (e.g., auto-saved notifications or manual edits), the account balance is updated inside a SQL transaction. This ensures data consistency without manual synchronization overhead in the UI.

## Open Questions

None. The requirements are clear, and the bugs found are blocking compilation and run-time features.

---

## Proposed Changes

### Component 1: Core Configuration & Models

#### [MODIFY] [pubspec.yaml](file:///c:/Users/Calvin/develop/projects/expense_tracker/pubspec.yaml)
* Correct version of `notification_listener_service` from `^3.2.0` to `^1.0.0` to resolve dependency resolution errors.

#### [MODIFY] [app_database.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/lib/core/database/app_database.dart)
* Wrap `createTransaction`, `updateTransaction`, and `deleteTransaction` in database transactions.
* Automatically update the corresponding account's `current_balance` when transactions are created, updated, or deleted.

---

### Component 2: Ingestion & Parser Logic

#### [NEW] [notification_parser.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/lib/features/ingestion/notification_parser.dart)
* Build the `NotificationParser` class.
* Implement Regex-based extraction of:
  * Transaction amount (supports `Rs.`, `INR`, `₹` formats with comma separators).
  * Transaction type (`credit` or `debit`).
  * Merchant name (infers from `to`, `at`, `on`, `for`, `info:`, `vpa:`, etc. and handles UPI Slash formatting like `UPI/Starbucks/123`).
  * Bank/provider name (HDFC, SBI, ICICI, Axis, etc.).
* Implement `_inferCategory` to dynamically map merchants to categories (e.g., food, shopping, utilities).

#### [MODIFY] [notification_service.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/lib/features/ingestion/notification_service.dart)
* Add support for checking/preventing duplicate listener subscriptions.
* Integrate `NotificationParser` to parse the notification content and title.
* Fetch all database accounts, match the parsed bank name to an existing account, fallback to the first account if none match, and save the transaction to the database.

---

### Component 3: UI & Entry Points

#### [MODIFY] [main.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/lib/main.dart)
* Call `NotificationService.initialize()` in `main()` to boot up the notification listener automatically if permissions are already granted.

#### [MODIFY] [onboarding_screen.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/lib/features/onboarding/presentation/onboarding_screen.dart)
* Call `NotificationService.initialize()` immediately after the user successfully grants notification permission on the UI tile.

---

### Component 4: Verification & Testing

#### [MODIFY] [widget_test.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/test/widget_test.dart)
* Fix the compiler error in the smoke test by updating the import and building `ExpenseTrackerApp` instead of `MyApp`.

#### [NEW] [notification_parser_test.dart](file:///c:/Users/Calvin/develop/projects/expense_tracker/test/notification_parser_test.dart)
* Write unit tests targeting the `NotificationParser` to verify amount, type, merchant, and bank extraction against various banking SMS formats.

---

## Verification Plan

### Automated Tests
* Run the Flutter tests:
  ```powershell
  C:\Users\Calvin\develop\flutter\bin\flutter.bat test
  ```
  Ensure all tests compile and pass successfully.

### Manual Verification
* Build and deploy the app to an Android device (via emulator or physical device if connected).
* Verify that granting permissions from the onboarding screen calls `NotificationService.initialize()` and prints events to logs.
