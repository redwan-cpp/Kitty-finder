# Set up Google sign-in for Kitty Finder (free, about 10 minutes)

Google requires every app that reads Google Drive to have its own OAuth
client. You do this once; everyone using your build of Kitty Finder shares it.

1. Go to <https://console.cloud.google.com/> and create a project named
   **Kitty Finder**.
2. **APIs & Services → Library**: search for **Google Drive API** and click
   **Enable**.
3. **Google Auth Platform → Branding** (older consoles call it "OAuth consent
   screen"): app name **Kitty Finder**, your email as the support and developer
   contact, then save.
4. **Audience**: choose **External**. Then click **Publish app** so the status
   is **In production**.
   - Don't leave it in **Testing**: test apps get sign-ins that expire every
     7 days, so everyone would have to sign in again each week.
   - Unverified production apps are limited to 100 users and show an
     "unverified app" screen once. People click **Advanced → Go to Kitty Finder**.
     That's fine for friends.
5. **Data Access → Add or remove scopes**: add
   `https://www.googleapis.com/auth/drive`, then save.
6. **Clients → Create client**: type **Desktop app**, name **Kitty Finder Mac**.
   Copy the **Client ID** and **Client secret**.
7. Either:
   - paste them into Kitty Finder → **Settings → Google**, or
   - to build them into the app for friends, copy
     `Config/GoogleOAuth.example.plist` to `Config/GoogleOAuth.plist`, fill
     it in, and run `scripts/package.sh`.

Google's documentation treats a desktop app's client secret as not truly
secret, so building it into the app is expected. Keep `Config/GoogleOAuth.plist`
out of public repos anyway (it's git-ignored).
