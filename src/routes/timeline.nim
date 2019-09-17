import asyncdispatch, strutils, sequtils, uri

import jester

import router_utils
import ".."/[api, prefs, types, utils, cache, formatters, agents, search]
import ../views/[general, profile, timeline, status]

include "../views/rss.nimf"

export uri, sequtils
export router_utils
export api, cache, formatters, search, agents
export profile, timeline, status

type ProfileTimeline = (Profile, Timeline, seq[GalleryPhoto])

proc fetchSingleTimeline*(name, after, agent: string;
                          query: Option[Query]): Future[ProfileTimeline] {.async.} =
  let railFut = getPhotoRail(name, agent)

  var timeline: Timeline
  var profile: Profile
  var cachedProfile = hasCachedProfile(name)

  if cachedProfile.isSome:
    profile = get(cachedProfile)

  if query.isNone:
    if cachedProfile.isSome:
      timeline = await getTimeline(name, after, agent)
    else:
      (profile, timeline) = await getProfileAndTimeline(name, agent, after)
      cache(profile)
  else:
    var timelineFut = getTimelineSearch(get(query), after, agent)
    if cachedProfile.isNone:
      profile = await getCachedProfile(name, agent)
    timeline = await timelineFut

  if profile.username.len == 0: return
  return (profile, timeline, await railFut)

proc fetchMultiTimeline*(names: seq[string]; after, agent: string;
                         query: Option[Query]): Future[Timeline] {.async.} =
  var q = query
  if q.isSome:
    get(q).fromUser = names
  else:
    q = some(Query(kind: multi, fromUser: names, excludes: @["replies"]))

  return await getTimelineSearch(get(q), after, agent)

proc showTimeline*(name, after: string; query: Option[Query];
                   prefs: Prefs; path, title, rss: string): Future[string] {.async.} =
  let agent = getAgent()
  let names = name.strip(chars={'/'}).split(",").filterIt(it.len > 0)

  if names.len == 1:
    let (p, t, r) = await fetchSingleTimeline(names[0], after, agent, query)
    if p.username.len == 0: return
    let pHtml = renderProfile(p, t, r, prefs, path)
    return renderMain(pHtml, prefs, title, pageTitle(p), pageDesc(p), path, rss=rss)
  else:
    let
      timeline = await fetchMultiTimeline(names, after, agent, query)
      html = renderMulti(timeline, names.join(","), prefs, path)
    return renderMain(html, prefs, title, "Multi")

template respTimeline*(timeline: typed) =
  if timeline.len == 0:
    resp Http404, showError("User \"" & @"name" & "\" not found", cfg.title)
  resp timeline

proc createTimelineRouter*(cfg: Config) =
  setProfileCacheTime(cfg.profileCacheTime)

  router timeline:
    get "/@name/?":
      cond '.' notin @"name"
      let rss = "/$1/rss" % @"name"
      respTimeline(await showTimeline(@"name", @"after", none(Query), cookiePrefs(),
                                      getPath(), cfg.title, rss))

    get "/@name/search":
      cond '.' notin @"name"
      let query = initQuery(@"filter", @"include", @"not", @"sep", @"name")
      respTimeline(await showTimeline(@"name", @"after", some(query),
                                      cookiePrefs(), getPath(), cfg.title, ""))

    get "/@name/replies":
      cond '.' notin @"name"
      let rss = "/$1/replies/rss" % @"name"
      respTimeline(await showTimeline(@"name", @"after", some(getReplyQuery(@"name")),
                                      cookiePrefs(), getPath(), cfg.title, rss))

    get "/@name/media":
      cond '.' notin @"name"
      let rss = "/$1/media/rss" % @"name"
      respTimeline(await showTimeline(@"name", @"after", some(getMediaQuery(@"name")),
                                      cookiePrefs(), getPath(), cfg.title, rss))

    get "/@name/status/@id":
      cond '.' notin @"name"
      let prefs = cookiePrefs()

      let conversation = await getTweet(@"name", @"id", getAgent())
      if conversation == nil or conversation.tweet.id.len == 0:
        if conversation != nil and conversation.tweet.tombstone.len > 0:
          resp Http404, showError(conversation.tweet.tombstone, cfg.title)
        else:
          resp Http404, showError("Tweet not found", cfg.title)

      let path = getPath()
      let title = pageTitle(conversation.tweet.profile)
      let desc = conversation.tweet.text
      let html = renderConversation(conversation, prefs, path)

      if conversation.tweet.video.isSome():
        let thumb = get(conversation.tweet.video).thumb
        let vidUrl = getVideoEmbed(conversation.tweet.id)
        resp renderMain(html, prefs, cfg.title, title, desc, path, images = @[thumb],
                        `type`="video", video=vidUrl)
      elif conversation.tweet.gif.isSome():
        let thumb = get(conversation.tweet.gif).thumb
        let vidUrl = getVideoEmbed(conversation.tweet.id)
        resp renderMain(html, prefs, cfg.title, title, desc, path, images = @[thumb],
                        `type`="video", video=vidUrl)
      else:
        resp renderMain(html, prefs, cfg.title, title, desc, path,
                        images=conversation.tweet.photos, `type`="photo")

    get "/i/web/status/@id":
      redirect("/i/status/" & @"id")