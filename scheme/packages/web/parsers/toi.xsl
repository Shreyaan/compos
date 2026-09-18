<?xml version="1.0" encoding="UTF-8"?>
<!-- timesofindia.indiatimes.com, which wraps one story in a megabyte of
     edition switchers, city menus, ad slots and recommendation widgets.
     The class names are hashed per build, so every rule here hangs off
     something the site means and not off a name: data-articlebody on the
     story body, the word byline in a class token, /articleshow/ in a
     headline's href, and the empty span the site uses for a paragraph
     break.

     An article page reads as headline, byline and body. Any other page,
     the front page or a section or a city, reads as its headlines, one
     per line, each still a link. A page that is neither reads thin, and
     browse falls back to the full document on its own. -->
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <!-- the front page links the same story from several cards -->
  <xsl:key name="by-href" match="a" use="@href"/>

  <xsl:template match="/">
    <html>
      <body>
        <xsl:choose>
          <xsl:when test="//div[@data-articlebody]">
            <h1><xsl:value-of select="normalize-space((//h1)[1])"/></h1>
            <xsl:for-each
              select="(//*[contains(concat(' ', normalize-space(@class), ' '), ' byline ')])[1]">
              <p><xsl:apply-templates select="node()" mode="keep"/></p>
            </xsl:for-each>
            <xsl:apply-templates select="(//div[@data-articlebody])[1]" mode="keep"/>
          </xsl:when>
          <xsl:otherwise>
            <h1><xsl:value-of select="normalize-space((//title)[1])"/></h1>
            <ul>
              <xsl:apply-templates mode="row" select="//a[
                contains(@href, '/articleshow/') and
                string-length(normalize-space(.)) &gt; 20 and
                generate-id() = generate-id(key('by-href', @href)[1])]"/>
            </ul>
          </xsl:otherwise>
        </xsl:choose>
      </body>
    </html>
  </xsl:template>

  <!-- ONE HEADLINE. A card carries its section label in a section
       element and often a second, longer line in a p: the label leads
       the line, the p stays out, and the title alone is the link. A card
       whose only words are that p keeps them rather than read empty. -->
  <xsl:template match="a" mode="row">
    <xsl:variable name="kicker" select="normalize-space((.//section)[1])"/>
    <xsl:variable name="title"><xsl:apply-templates select="node()" mode="text"/></xsl:variable>
    <li>
      <xsl:if test="$kicker != ''">
        <strong><xsl:value-of select="$kicker"/></strong>
        <xsl:text> &#8212; </xsl:text>
      </xsl:if>
      <a href="{@href}">
        <xsl:choose>
          <xsl:when test="normalize-space($title) != ''">
            <xsl:value-of select="normalize-space($title)"/>
          </xsl:when>
          <xsl:otherwise><xsl:value-of select="normalize-space(.)"/></xsl:otherwise>
        </xsl:choose>
      </a>
    </li>
  </xsl:template>

  <xsl:template match="text()" mode="text"><xsl:value-of select="."/></xsl:template>
  <xsl:template match="*" mode="text">
    <xsl:apply-templates select="node()" mode="text"/>
  </xsl:template>
  <xsl:template match="section|p|img|button|i|svg|script|style|figcaption" mode="text"/>
  <xsl:template match="br" mode="text"><xsl:text> </xsl:text></xsl:template>

  <!-- THE STORY BODY. Its prose is one flat run of text broken by empty
       spans, not by paragraph tags, so the run is grouped back into
       paragraphs here: a block that stood before the run's first words
       stays before them, the words become a p, and a block that followed
       them follows. Without this the body arrives as one wall of text. -->
  <xsl:template mode="keep" match="*[span[not(node())][contains(concat(' ', normalize-space(@class), ' '), ' br ')]]">
    <xsl:call-template name="toi-paragraph">
      <xsl:with-param name="nodes" select="node()[
        count(preceding-sibling::span[not(node())][contains(concat(' ', normalize-space(@class), ' '), ' br ')]) = 0]"/>
    </xsl:call-template>
    <xsl:for-each select="span[not(node())][contains(concat(' ', normalize-space(@class), ' '), ' br ')]">
      <xsl:variable name="n" select="position()"/>
      <xsl:call-template name="toi-paragraph">
        <xsl:with-param name="nodes" select="../node()[
          count(preceding-sibling::span[not(node())][contains(concat(' ', normalize-space(@class), ' '), ' br ')]) = $n]"/>
      </xsl:call-template>
    </xsl:for-each>
  </xsl:template>

  <xsl:template name="toi-paragraph">
    <xsl:param name="nodes"/>
    <xsl:variable name="inline" select="$nodes[self::text() or self::a or self::span
      or self::strong or self::b or self::em or self::br or self::keyword]"/>
    <xsl:variable name="blocks" select="$nodes[not(self::text() or self::a or self::span
      or self::strong or self::b or self::em or self::br or self::keyword)]"/>
    <xsl:choose>
      <xsl:when test="count($inline) &gt; 0">
        <xsl:variable name="first" select="$inline[1]"/>
        <xsl:apply-templates mode="keep"
          select="$blocks[following-sibling::node()[generate-id() = generate-id($first)]]"/>
        <p><xsl:apply-templates select="$inline" mode="keep"/></p>
        <xsl:apply-templates mode="keep"
          select="$blocks[not(following-sibling::node()[generate-id() = generate-id($first)])]"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:apply-templates select="$blocks" mode="keep"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- a layout wrapper says nothing a reading needs: keep what is inside -->
  <xsl:template match="div|section|figure|main|article|header|footer" mode="keep">
    <xsl:apply-templates select="node()" mode="keep"/>
  </xsl:template>

  <!-- an image's own caption, as its own line -->
  <xsl:template match="div[contains(@class, 'img_cptn')]" mode="keep">
    <p><em><xsl:value-of select="normalize-space(.)"/></em></p>
  </xsl:template>

  <xsl:template match="*" mode="keep">
    <xsl:copy>
      <xsl:copy-of select="@href|@alt|@title"/>
      <xsl:apply-templates select="node()" mode="keep"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="text()" mode="keep"><xsl:value-of select="."/></xsl:template>

  <xsl:template mode="keep"
    match="script|style|noscript|iframe|form|input|select|textarea|button|nav|i|svg|meta|link|video-embed"/>

  <!-- an empty span is a break the grouping already spent, or nothing -->
  <xsl:template match="span[not(node())]" mode="keep"/>

  <!-- ad slots, recommendation widgets, share rows, the app promo -->
  <xsl:template mode="keep" match="*[
      contains(@class, 'js_tbl_2ad') or
      contains(@class, 'mgid') or
      contains(@class, 'taboola') or
      contains(@class, 'readmore') or
      contains(@class, 'wdt-') or
      contains(@class, 'icon_share') or
      contains(@class, 'slick') or
      contains(@class, 'colombia') or
      contains(@class, 'dfp')]
    | *[@data-socialshare]
    | div[starts-with(normalize-space(.), 'Get the latest')]"/>

  <!-- a custom element pandoc would not know: keep the words, lose the tag -->
  <xsl:template match="keyword" mode="keep">
    <xsl:apply-templates select="node()" mode="keep"/>
  </xsl:template>

  <!-- the real image hides in data-src while src holds a placeholder -->
  <xsl:template match="img" mode="keep">
    <img>
      <xsl:attribute name="src">
        <xsl:choose>
          <xsl:when test="@data-src"><xsl:value-of select="@data-src"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="@src"/></xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:copy-of select="@alt|@title"/>
    </img>
  </xsl:template>
</xsl:stylesheet>
