# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, sequtils, strutils, strformat, tables, times, hashes, uri

import jester

import router_utils, timeline
import ../query

include "../views/rss.nimf"

export times, hashes

proc timelineRss*(req: Request; cfg: Config; query: Query): Future[Rss] {.async.} =
  var profile: Profile
  var q = query
  let
    name = req.params.getOrDefault("name")
    after = getCursor(req)
    names = getNames(name)
    count = parseInt(req.params.getOrDefault("count", "0"))

  if names.len == 1:
    profile = await fetchProfile(after, query, skipRail=true, skipPinned=true)
  else:
    q.fromUser = names
    profile = Profile(
      tweets: await getSearch[Tweet](q, after),
      # this is kinda dumb
      user: User(
        username: name,
        fullname: names.join(" | "),
        userpic: "https://abs.twimg.com/sticky/default_profile_images/default_profile.png"
      )
    )

  if profile.user.suspended:
    return Rss(feed: profile.user.username, cursor: "suspended")

  if profile.tweets.content.len > 0:
    while profile.tweets.content.len < count:
      let moreTweets = await getSearch[Tweet](q, profile.tweets.bottom)
      if moreTweets.content.len == 0:
        break
      profile.tweets.content = concat(profile.tweets.content, moreTweets.content)
      profile.tweets.bottom = moreTweets.bottom

  if profile.user.fullname.len > 0:
    let rss = renderTimelineRss(profile, cfg, multi=(names.len > 1))
    return Rss(feed: rss, cursor: profile.tweets.bottom)

template respRss*(rss, page) =
  if rss.cursor.len == 0:
    let info = case page
               of "User": &""" "{@"name"}" """
               of "List": &""" "{@"id"}" """
               else: " "

    resp Http404, showError(page & info & "not found", cfg)
  elif rss.cursor.len == 9 and rss.cursor == "suspended":
    resp Http404, showError(getSuspended(@"name"), cfg)

  let headers = {"Content-Type": "application/rss+xml; charset=utf-8",
                 "Min-Id": rss.cursor}
  resp Http200, headers, rss.feed

proc createRssRouter*(cfg: Config) =
  router rss:
    get "/search/rss":
      cond cfg.enableRss
      if @"q".len > 200:
        resp Http400, showError("Search input too long.", cfg)

      let query = initQuery(params(request))
      if query.kind != tweets:
        resp Http400, showError("Only Tweet searches are allowed for RSS feeds.", cfg)

      let
        cursor = getCursor()
        key = &"search:{hash(genQueryUrl(query))}:cursor"

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "Search")

      let tweets = await getSearch[Tweet](query, cursor)
      rss.cursor = tweets.bottom
      rss.feed = renderSearchRss(tweets.content, query.text, genQueryUrl(query), cfg)

      await cacheRss(key, rss)
      respRss(rss, "Search")

    get "/@name/rss":
      cond cfg.enableRss
      cond '.' notin @"name"
      let
        cursor = getCursor()
        name = @"name"
        count = @"count"
        key = &"twitter:{name}:{cursor}:{count}"

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "User")

      rss = await timelineRss(request, cfg, Query(fromUser: @[name]))

      await cacheRss(key, rss)
      respRss(rss, "User")

    get "/@name/@tab/rss":
      cond cfg.enableRss
      cond '.' notin @"name"
      cond @"tab" in ["with_replies", "media", "search"]
      let name = @"name"
      let query =
        case @"tab"
        of "with_replies": getReplyQuery(name)
        of "media": getMediaQuery(name)
        of "search": initQuery(params(request), name=name)
        else: Query(fromUser: @[name])

      var key = &"""{@"tab"}:{@"name"}:"""
      if @"tab" == "search":
        key &= $hash(genQueryUrl(query)) & ":"
      key &= getCursor()

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "User")

      rss = await timelineRss(request, cfg, query)

      await cacheRss(key, rss)
      respRss(rss, "User")

    get "/@name/lists/@slug/rss":
      cond cfg.enableRss
      cond @"name" != "i"
      let
        slug = decodeUrl(@"slug")
        list = await getCachedList(@"name", slug)
        cursor = getCursor()

      if list.id.len == 0:
        resp Http404, showError(&"""List "{@"slug"}" not found""", cfg)

      let url = &"/i/lists/{list.id}/rss"
      if cursor.len > 0:
        redirect(&"{url}?cursor={encodeUrl(cursor, false)}")
      else:
        redirect(url)

    get "/i/lists/@id/rss":
      cond cfg.enableRss
      let
        cursor = getCursor()
        key =
          if cursor.len == 0: "lists:" & @"id"
          else: &"""lists:{@"id"}:{cursor}"""

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "List")

      let
        list = await getCachedList(id=(@"id"))
        timeline = await getListTimeline(list.id, cursor)
      rss.cursor = timeline.bottom
      rss.feed = renderListRss(timeline.content, list, cfg)

      await cacheRss(key, rss)
      respRss(rss, "List")
