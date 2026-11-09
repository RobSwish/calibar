# Google Meet and invitations

CaliBar can create a Google Meet link and invite people while you create an event, without opening Apple Calendar or Google Calendar. It's optional. Without a Google client ID in the build, the feature is hidden and CaliBar never contacts Google.

## How it behaves

- The **Google Meet** icon sits at the end of the location field in the new-event editor. The first time you click it, it asks you to sign in to Google. After that it’s one click, and clicking again removes the link.
- **Google calendars** (Google accounts added to Apple Calendar): CaliBar creates the event through the Google Calendar API, and Google attaches a native Meet conference, the same as one made on calendar.google.com. Apple Calendar then syncs the event down. CaliBar shows the event straight away and asks macOS to sync sooner.
- **iCloud and other calendars**: CaliBar creates a standalone Meet room through the Google Meet API. It then saves the event through Apple Calendar (EventKit) with the link in the URL and notes.
- CaliBar falls back to the standalone-link route if the Google calendar can't be matched for certain, or if the draft uses something the Google Calendar API can't represent: Tentative/Unavailable, sound alerts, alerts after or on a set date, alerts more than four weeks before, or email alerts to another address. Nothing you chose is dropped.
- **Invitees** appear under the Meet button when the chosen calendar belongs to the connected Google account. Type or paste addresses (commas, semicolons and `Name <email>` work). CaliBar saves the event through the Google Calendar API and Google emails the invitations (`sendUpdates=all`). Events without invitees notify nobody (`sendUpdates=none`).
- Apple Calendar's API (EventKit) can't add invitees, so invitations don't fall back to Apple Calendar. If the calendar isn't a Google calendar, or the event uses something Google can't store (see above), CaliBar says so and saves nothing, rather than dropping the invitees.
- Until Google's calendar list loads, CaliBar guesses which calendars are Google from the account name. After that, it matches against the signed-in account exactly.
- Only the Google refresh token, account email and granted scopes are stored, in the macOS Keychain. **Settings → Google Meet → Disconnect** removes them and revokes access at Google.

Scopes requested: `openid`, `email`, `calendar.events`, `calendar.calendarlist.readonly` and `meetings.space.created`.

## Google Cloud setup (one time)

1. In [Google Cloud console](https://console.cloud.google.com/), create a project (for example "CaliBar").
2. **APIs & Services → Library**: enable **Google Calendar API** and **Google Meet REST API**.
3. **Google Auth Platform → Branding**: set the app name (CaliBar), support email and developer contact. Under **Audience**, choose **External**.
4. **Google Auth Platform → Data Access → Add or remove scopes**: add the five scopes above.
5. **Google Auth Platform → Clients → Create client**: application type **iOS**, bundle ID `com.robswift.Daybar`. If Advanced settings offers **Enable custom URI scheme**, turn it on. CaliBar signs in through `ASWebAuthenticationSession` and receives the reply on the reversed client ID scheme.
6. Copy the **Client ID**. It ends in `.apps.googleusercontent.com` and isn't a secret, since every installed app ships its client ID. Put it in `project.yml`:

   ```yaml
   GOOGLE_CLIENT_ID: '1234567890-abc123.apps.googleusercontent.com'
   ```

   Or pass it for a single build without committing it: `GOOGLE_CLIENT_ID=… ./scripts/build.sh` (`scripts/release.sh` honours it too).
7. Build, open CaliBar, then **Settings → Google Meet → Connect Google**.

## Publishing status

- **Testing** (the default): only accounts listed under **Audience → Test users** can sign in (up to 100). Google expires refresh tokens for apps in Testing after **7 days**, so CaliBar will ask you to reconnect weekly.
- **In production, unverified**: anyone can sign in, but Google shows an "unverified app" warning (Advanced → Go to CaliBar), with a cap of 100 users. Tokens no longer expire weekly. This suits personal use.
- **In production, verified**: needed for a public release on calibar.app with no warning screen. `calendar.events` is a sensitive scope, so Google reviews the app. Expect to provide a privacy policy on calibar.app, a homepage and a short demo video. Review can take several weeks.

## Testing without Google

`open -n build/CaliBar.app --args --demo --demo-add` shows the Google Meet icon in demo mode. Saving a demo event adds the sample Meet link and contacts nobody.
