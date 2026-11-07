# How we handle personal information

*Effective: 20 June 2026*

*This is a translation of the Japanese policy. If the two differ, the Japanese text applies.*

> This server is a small place, run by one person.
> Here is an honest account of how the information gathered here is handled.
>
> The operator lives in South Korea and the server is hosted in Japan. Many of the people who use it are in Japan, so this policy is built on **Japan's Act on the Protection of Personal Information (APPI)**.
>
> **If you're reading this from somewhere else, nothing about what we collect or how we treat it is different for you.** The sections below on what we collect, who can see it, how long we keep it and who handles it are the same for everyone. What differs is only which law stands behind them. Section 12 says so plainly. Japanese and Korean versions are also available.

---

## 1. The operator and the contact point

Since it's run by one person, the operator is the contact point.

- **Email**: f3liz-dev@proton.me
- **ActivityPub**: @kuro_admin@sukhi.f3liz.casa

For questions, complaints or exercising your rights about personal information, please feel free to use the contacts above.

---

## 2. The information we collect

**Account information** — username, email address, display name, bio, profile and header images, language setting

**Information used to log in** — used to confirm it's you when you log in. If you set a password, its hash (a form that can't be turned back). If you use two-step verification with an authenticator app, that setting. **If you register a passkey, its public key and credential ID.** A passkey's private key stays only on your device or authenticator and never reaches the server: we receive only the public key.

**What you post**
- Posts and replies — the text, the audience (public, unlisted, followers only, direct), and the time of posting
- Media such as photos and videos, and any alternative text (alt text) you add
- Polls, and what you voted

**Activity that builds up on the server** — reactions, boosts, bookmarks, follow and follower relationships, accounts you block or mute, mentions

**Push notifications** — if you turn them on, we store the address information needed to send notifications to your device (such as the browser's Web Push subscription). Depending on the preview setting, a notification may include part of a post.

**Invitation information** — because sign-up is currently by invitation, we record who invited whom, the invitation links created, and how many times each was used.

**Automatically recorded information** — server logs such as connection time, IP address and browser information (user agent), and the ActivityPub data exchanged in the course of federation

> **What is federation?**
> This server is connected, by the same agreement (the ActivityPub protocol), to servers that people around the world run for themselves, such as Mastodon and Misskey. Thanks to this, people on different servers can follow and talk to each other.
>
> For this connection to work, some information, such as posts and profiles, has to pass to the other servers. Information that has passed is managed according to the other server's policy, and once it has gone, it can sometimes be hard for us to take it back completely.
>
> Public and unlisted posts, profiles and follow relationships pass to other servers through federation. Followers-only and direct (DM) posts reach only the people they're for, but they do pass as far as the servers those people are on. So even DMs don't stay only inside this server.

**How far, and to whom, it's visible (the audience)**

Here is, honestly, who can see the information we collect, and how far, through this site and the API. It falls broadly into three groups. Information you've made public is still your personal information. We handle it within the purpose for which it was made public.

*① What you made public — anyone can see it*

Posts you made public or unlisted, and the contents of your profile, can be seen by people who aren't logged in, through the API apps use, through search, and from other servers in the federation. As the word "public" says, this is information we don't hide.

- The text, images and posting time of public and unlisted posts, and threads (the flow of a conversation)
- Display name, username, bio, icon, header image, account creation date, bot flag, and whether the account is locked
- The numbers of follows and followers, and **the lists of follows and followers themselves** (who you follow, and who follows you)
- The *number* of reactions and boosts (not who pressed them; see ③)
- Search results by username and hashtag, and basic information about the server (domain, name, version and so on)

It may be a little surprising that even the lists of follows and followers are public. This is common practice across the federation (Mastodon and others), so I'm telling you in advance. See also "What is federation?" just above, on what passes to servers outside.

*② What you shared with a limited audience — only that audience*

Followers-only posts reach only your followers, and direct messages (DMs) reach only the people addressed. When the API reads a profile's list of posts or an individual post, it returns it only to people who are allowed to see it. Viewing and voting in a poll, and reacting to a post, can also be done only by people who can see that post. DMs are delivered only to the inbox of the people addressed, and only public posts go out through the public routes of federation (the outbox and fetching a post directly), so followers-only posts and DMs don't leak from there.

*③ What we don't make visible — only you can see it*

The following is never handed to other users, to the API, or to the federation. Only you can see it, from your own account.

- Your email address, IP address, password (hash), the credentials for two-step verification and passkeys, authentication tokens, and the secret half of encryption keys
- *Who* pressed a reaction or boost, and who a notification was delivered to
- Your lists of blocked and muted accounts, and who invited you
- The address information for push notifications, and the recipients of DMs

Note that displays of a relationship such as "I'm following / blocking this person" are shown only to you, and only while you're logged in.

---

## 3. What we use it for (purpose of use)

We use the information we collect **only for managing accounts, displaying posts, providing the federation features, and keeping the service secure and preventing abuse**. We don't use it for advertising or marketing.

We state the purposes of use in this policy (specified under Article 17 of the APPI, and made public under Article 21). We don't use the information beyond the scope of these purposes (Article 18 of the same Act).

---

## 4. How long we keep it, and deletion

| Item | How long we keep it |
|------|-----------|
| Account information | Until you leave |
| Information used to log in (passkeys, two-step verification and so on) | Until you remove it, or leave |
| Posts | When you ask us to delete them, or when you leave |
| Push notification addresses | Until you turn notifications off, or leave |
| Connection logs (IP and so on) | Deleted automatically after 30 days |
| Records of moderation and security actions (suspensions, blocks and so on) | Kept without a time limit, for accountability and for dealing with abuse |
| Federation (ActivityPub) data and archives | While the service is in operation |

Information past its retention period is deleted in a form that can't be restored. There are, however, some parts where we can't easily promise complete deletion. I'm telling you in advance.

- Posts that have passed through federation may remain as copies on the other servers (§5).
- The federation activity archive kept for the server's integrity and recovery may remain after you leave.
- Records of moderation and security actions are kept without a time limit for accountability, but they don't include the text of posts; only the minimum "who, when, what and why" is kept, protected in a form that can't be rewritten or erased afterwards.

---

## 5. Entrusting information, and handling in other countries

For running and securing the server, we use the following providers.

| Provider | Information handled | Location | Role |
|--------|----------|------|------|
| Oracle Corporation (Oracle Cloud Infrastructure) | Information stored on the server, such as accounts and posts | Japan | Running the server (storing and processing data) |
| Cloudflare, Inc. | Connecting IP addresses, cookies, traffic logs | United States and elsewhere | CDN and security (DDoS and bot protection) |

- The server itself is in **Japan** (Oracle Cloud Infrastructure), where data is stored and processed. As a provider in Japan we supervise it so that data is handled safely (Article 25 of the APPI).
- Connections pass through **Cloudflare** (United States and elsewhere), so some information may be handled in other countries. Cloudflare relays and caches traffic as a CDN and security service, and doesn't handle the stored content for its own purposes (the so-called cloud exception). For that reason we believe this isn't "provision to a third party in a foreign country" (Article 28 of the same Act), but, bearing in mind that handling takes place abroad, we take security control measures (understanding the external environment). (Cloudflare's privacy policy: <https://www.cloudflare.com/privacypolicy/>)
- This handling is essential to providing the service. If you don't want it, it would be difficult for you to register for and use this service. If you stop wanting it after you register, you can stop the handling by leaving.

**Sending through federation can amount to provision to other countries.** Public posts and profiles pass to the other servers where your followers are, and those servers are scattered around the world (inside and outside Japan). Who they pass to changes depending on whom you follow, it's hard to specify in advance, and what has passed is managed according to each server's policy. If you don't want that, you can reduce how far it passes by posting non-publicly, blocking particular servers and so on (see also §2).

---

## 6. Providing information to third parties

Except in the following cases, we don't provide personal information to third parties (Article 27 of the APPI).

- When there is a request based on law, such as from a court or an investigating authority
- When a post passes to other servers where your followers are, in accordance with the federation protocol (ActivityPub)

---

## 7. Keeping information safe (security control measures)

It's a small server, but to protect the information you've entrusted to us, we do the following (Article 23 of the APPI).

- Passwords are stored in a form that can't be reversed (one-way hashing).
- To log in you can use a passkey as well as a password. A passkey confirms who you are with a private key inside your device, so the server doesn't have to hold a secret passphrase for you.
- Information is exchanged over encrypted connections (HTTPS).
- Only the operator holds administrator authority, and records of administrative actions are kept in a form that can't be rewritten or erased afterwards.
- We collect only the information we need, and delete what's no longer needed.
- If personal information should ever leak, we'll tell the people affected promptly and take the necessary steps (§8 below).

---

## 8. If a leak or similar happens

When personal information is leaked, lost or damaged (a "leak or similar"), we respond in line with Article 26 of the APPI.

- In particular, in any of the following cases, we **report to the Personal Information Protection Commission** and **notify the people affected**.
  - When it includes special care-required personal information (health, beliefs and so on)
  - When misuse could cause financial harm
  - When it's caused by an act with a wrongful purpose (unauthorised access, ransomware and so on)
  - When more than 1,000 people are affected
- Reports are made first as a **preliminary report** (promptly after we notice; the guide is roughly within 3 to 5 days), then a **final report** (within 30 days; within 60 days where it's caused by an act with a wrongful purpose, such as unauthorised access).
- Whatever the scale or kind, if we notice a leak, we'll tell the people affected as far as we can.

---

## 9. Your rights over your information

These rights are written from the APPI (Articles 33 to 35), but we offer them to everyone, wherever you live. You can ask for the following about the personal data we hold.

- **Disclosure** — disclosure of the information we hold about you (you can also ask for it as electronic records, that is, as data).
- **Correction, addition and deletion** — when the content isn't true.
- **Stopping use, and erasure** — when we no longer need to use it, when a leak or similar has occurred, or when your rights or legitimate interests may be harmed (the situations where you can ask were widened by the 2022 amendment).
- **Stopping provision to third parties**.

**How to ask**: by email (f3liz-dev@proton.me) or DM. We'll respond after confirming that you are the person concerned, or a legitimate representative.

**Our response**: we'll respond without delay. If it's going to take time, we'll tell you first. For disclosure and the like we may charge a fee within the actual cost (my intention is basically to respond free of charge).

**Outside places to turn to**: if it's hard to resolve things through me, you can consult the following.
- Personal Information Protection Commission [ppc.go.jp](https://www.ppc.go.jp) / APPI consultation line ☎ 03-6457-9849

---

## 10. Cookies and browser storage

To keep you logged in, and to show pages the way you chose, we use three things. All are the minimum necessary.

- **Session cookie** — a cookie to keep you logged in for a short while on the login and admin pages (signed on the server to prevent tampering).
- **Language and time-zone cookies** — they remember the language you chose and the name of your time zone (for example `Asia/Tokyo`), so that times are shown as your local time of day. They contain nothing that identifies you.
- **Browser storage (localStorage)** — the web app (SPA) stores the authentication token it receives after you log in in the browser's localStorage, not in a cookie. It logs in to the API with this token.
- **Browser storage (drafts)** — while you write an article in the web app, the half-written title and text are kept in your device's localStorage only. They are never sent to the server. Once you send the article they are cleared the next time you open the writing page, and you can clear them yourself with the discard button there.

In addition, for bot and abuse protection, the security tool (Anubis) and Cloudflare on the connection path may set cookies for security purposes.

**We don't use cookies for advertising or tracking.** You can delete or refuse cookies and storage in your browser's settings, but if you do, some features such as logging in may not work properly.

---

## 11. About children

This server has no age verification. **If you are around 15 or younger, please talk with a parent or guardian first.** If we learn that someone is using it without a guardian's consent, we'll delete the account promptly. If you notice such a case, please tell the operator.

---

## 12. Which law stands behind this

This server is run by an operator who lives in South Korea, who also follows South Korea's Personal Information Protection Act (PIPA). Because we provide the service to people living in Japan, **Japan's Act on the Protection of Personal Information (APPI) reaches the operator too, by extraterritorial application.** This policy is written in line with the APPI.

**If you live somewhere else**, such as the United Kingdom, North America or Australia: we haven't set up anything specific to your country's law. We don't offer or advertise the service to people living in the EU or EEA, and we don't provide individual assurances corresponding to the EU's General Data Protection Regulation (GDPR), such as appointing a representative in the EU. What we can promise is what this page says: the same handling, the same retention, and the same rights as in §9, for everyone.

Wherever you live, if you send a request to see, correct or delete your information by the method in §9, we'll respond sincerely.

---

## 13. If this policy changes

If the content changes, the operator account will let you know. For important changes, we'll tell you at least 7 days beforehand.

---

*This policy is written on the basis of Japan's Act on the Protection of Personal Information and the guidelines of the Personal Information Protection Commission. For the latest and accurate content, please also check the information from the Personal Information Protection Commission ([ppc.go.jp](https://www.ppc.go.jp)).*
