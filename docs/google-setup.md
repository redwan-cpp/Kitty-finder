# Set up Google sign-in for Kitty Finder (free, about 15 minutes)

Google requires every app that reads Google Drive to have its own OAuth
client. You do this once; everyone using your build of Kitty Finder shares it.
This repository doesn't include one, so each person who builds the app makes
their own.

1. Go to <https://console.cloud.google.com/> and create a project, for
   example **Kitty Finder**.
2. **APIs & Services → Library**: search for **Google Drive API** and click
   **Enable**.
3. **Google Auth Platform → Get started** (older consoles call it "OAuth
   consent screen"):
   - App name: **Kitty Finder**; support email: your email.
   - Audience: **External**.
   - Contact email: your email.
   - Agree to Google's API Services User Data Policy and click **Create**.
4. **Data Access → Add or remove scopes**: paste
   `https://www.googleapis.com/auth/drive` into "Manually add scopes", click
   **Add to table**, **Update**, then **Save**.
5. **Clients → Create client**: type **Desktop app**, name **Kitty Finder Mac**,
   then **Create**.
   - Google shows the client secret **only once**, until the page reloads. In
     the dialog that appears, click **Download JSON**.
   - If you missed it, open the client, use **Add secret**, and download it
     straight away. A client can have at most two secrets, so delete unused
     ones first.
6. Put the client into Kitty Finder, either:
   - `scripts/import-google-client.sh ~/Downloads/client_secret_*.json` to
     build it into the app (writes `Config/GoogleOAuth.plist`, git-ignored), or
   - copy `Config/GoogleOAuth.example.plist` to `Config/GoogleOAuth.plist` and
     fill it in by hand, or
   - paste the ID and secret into Kitty Finder → **Settings → Google**.
7. Choose who can sign in (**Audience**):
   - **Testing** (the default): only accounts you list under **Test users**
     can sign in, and their sign-in expires every 7 days. Good for trying it
     out.
   - **In production** (**Publish app**), for everyday use. Google first asks
     for a public home page and privacy policy:
     - Publish the pages in `site/` (for example with GitHub Pages or Vercel).
     - Enter their addresses under **Branding**, and the site's domain under
       **Authorized domains**.
     - Unverified production apps work for up to 100 users and show a one-time
       "Google hasn't verified this app" screen (**Advanced → Go to Kitty
       Finder**).

Google's documentation treats a desktop app's client secret as not truly
secret, so building it into the app is expected. Still, keep
`Config/GoogleOAuth.plist` out of public repositories (it's git-ignored), so
nobody else uses up your app's 100-user limit.
