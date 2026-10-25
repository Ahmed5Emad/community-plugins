# Maildir

Show unread mail count in specified Maildir paths.

## Plugin

| Field | Value |
| ---| --- |
| ID | `nickh/maildir` |
| Entries | Bar widget: `maildir` |

## Usage

Add the `maildir` widget from Noctalia's widget picker.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `maildir` | `string` | `~/Mail` | Path to maildir tree |
| `inboxes` | `string_list` | `[INBOX:in]` | List of inbox locations to montor, with `:label` appended |
| `update_interval` | `int` | `10` | Period in seconds between checks for new mail |
| `click_command` | `string` | `""` | Command to run when widget is clicked |
