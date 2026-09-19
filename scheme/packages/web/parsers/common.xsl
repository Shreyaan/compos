<?xml version="1.0" encoding="UTF-8"?>
<!-- common.xsl - the rules every learned sheet needs.

     A learned sheet says what to delete from one site. This says what to
     do with what is left, and it says it for every site at once: a sheet
     imports it, so a rule fixed here is fixed everywhere, with no site
     learned again.

     An imported rule has lower precedence than the sheet's own, so a
     site parser may still overrule any of this. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <!-- Copy by default. Everything below is an exception to this. -->
  <xsl:template match="@*|node()" mode="copy">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" mode="copy"/>
    </xsl:copy>
  </xsl:template>

  <!-- Every word under here, on one line, with single spaces. A card
       writes its section and its headline as two boxes with no space
       between them, because the space is in the stylesheet. Text has no
       stylesheet, so without this "US" and "Trump ally" arrive as
       "USTrump". -->
  <xsl:template name="words">
    <xsl:for-each select=".//text()">
      <xsl:if test="normalize-space(.) != ''">
        <xsl:value-of select="normalize-space(.)"/>
        <xsl:text> </xsl:text>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- The same headline twice. A responsive page ships one copy of each
       card for the wide layout and one for the narrow, and the page reads
       double. A headline is its link: the first card with a given address
       is the card, and a later one with the same address is the copy.
       Keyed, so the test costs a lookup and not a search. -->
  <xsl:key name="headline"
           match="a[@href][.//h1 or .//h2 or .//h3 or .//h4 or .//h5 or .//h6]|a[@href][ancestor::h1|ancestor::h2|ancestor::h3|ancestor::h4|ancestor::h5|ancestor::h6]"
           use="@href"/>

  <xsl:key name="overlay" match="a[@href][not(normalize-space(.))]" use="@href"/>

  <!-- A heading is one line of text, and nothing else. A card builds its
       headline out of boxes, and a box inside a heading reaches Markdown
       as a paragraph: the heading empties, the words fall out below it,
       and a link around them comes out with no label at all. -->
  <xsl:template match="h1|h2|h3|h4|h5|h6" mode="copy">
    <xsl:if test="normalize-space(.) != ''">
      <h2><xsl:call-template name="words"/></h2>
    </xsl:if>
  </xsl:template>

  <xsl:template match="h1[.//a/@href]|h2[.//a/@href]|h3[.//a/@href]|h4[.//a/@href]|h5[.//a/@href]|h6[.//a/@href]" mode="copy">
    <xsl:if test="normalize-space(.) != '' and count((.//a[@href])[1] | key('headline', (.//a[@href])[1]/@href)[1]) = 1">
      <h2><a href="{(.//a[@href])[1]/@href}"><xsl:call-template name="words"/></a></h2>
    </xsl:if>
  </xsl:template>


  <!-- The card lays an empty link over the whole tile, and the heading
       under it has no link of its own: the anchor carries the address
       and an aria-label, and nothing a text reading can see. Give the
       heading that address. The words stay the card's own, so the
       section kicker the aria-label drops is kept. -->
  <xsl:template match="h1[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]|h2[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]|h3[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]|h4[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]|h5[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]|h6[not(.//a/@href)][ancestor::*[a[@href][not(normalize-space(.))]]]" mode="copy">
    <xsl:variable name="over" select="(ancestor::*[a[@href][not(normalize-space(.))]][1]/a[@href][not(normalize-space(.))])[1]"/>
    <xsl:if test="normalize-space(.) != '' and count($over | key('overlay', $over/@href)[1]) = 1">
      <h2><a href="{$over/@href}"><xsl:call-template name="words"/></a></h2>
    </xsl:if>
  </xsl:template>

  <!-- A card wraps its heading inside the link, the other way round.
       Markdown holds no block inside a link, so the link comes out empty
       and the heading follows it. Put the link inside the heading: the
       label is the headline, and RET still follows it. -->
  <xsl:template match="a[.//h1 or .//h2 or .//h3 or .//h4 or .//h5 or .//h6]" mode="copy">
    <xsl:if test="count(. | key('headline', @href)[1]) = 1">
      <h2><a href="{@href}">
        <xsl:for-each select="(.//h1|.//h2|.//h3|.//h4|.//h5|.//h6)[1]">
          <xsl:call-template name="words"/>
        </xsl:for-each>
      </a></h2>
      <xsl:apply-templates mode="copy" select="node()[not(descendant-or-self::h1 or descendant-or-self::h2 or descendant-or-self::h3 or descendant-or-self::h4 or descendant-or-self::h5 or descendant-or-self::h6)]"/>
    </xsl:if>
  </xsl:template>

  <!-- Nothing here is read. -->
  <xsl:template match="script|style|noscript|template|iframe|canvas|svg" mode="copy"/>
  <xsl:template match="form|input|button|select|textarea|label" mode="copy"/>

  <!-- A photograph is content and stays. What goes with it is the rest
       of the picture markup: a <source> is the same image again at
       another width, and a <picture> that keeps its <img> needs no
       wrapper. -->
  <xsl:template match="source" mode="copy"/>
  <xsl:template match="picture" mode="copy">
    <xsl:apply-templates select="img" mode="copy"/>
  </xsl:template>

  <!-- An image with no alt text is not for a reader: it is a counter, a
       spacer or an icon. The convention is the author's own, so this
       believes it. An inlined data: image is always an icon. -->
  <xsl:template match="img[not(normalize-space(@alt))]" mode="copy"/>
  <xsl:template match="img[starts-with(@src, 'data:')]" mode="copy"/>

  <!-- The same card twice. A responsive page ships one copy for the wide
       layout and one for the narrow, and marks the one it is not
       showing. Both copies reach a text reading. -->
  <xsl:template match="*[@aria-hidden='true']" mode="copy"/>
  <xsl:template match="*[@hidden]" mode="copy"/>

  <!-- A label written for a screen reader alone. It tells someone who
       cannot see the layout what the thing beside it is: "Attribution",
       "Published", "Share this page". A text reading reads that thing
       anyway, so the label arrives as a bare word attached to nothing.
       The BBC front page carries 68 of them, one under every headline.
       The class name is the whole convention, and a framework spells it
       one of these few ways. -->
  <xsl:template match="*[contains(concat(' ', normalize-space(@class), ' '), ' visually-hidden ')
                         or contains(concat(' ', normalize-space(@class), ' '), ' visuallyhidden ')
                         or contains(concat(' ', normalize-space(@class), ' '), ' sr-only ')
                         or contains(concat(' ', normalize-space(@class), ' '), ' screen-reader-text ')
                         or contains(concat(' ', normalize-space(@class), ' '), ' screen-reader-only ')
                         or contains(concat(' ', normalize-space(@class), ' '), ' a11y-hidden ')]"
                mode="copy"/>

  <!-- An anchor with no text is not a link a reader can follow. -->
  <xsl:template match="a[not(normalize-space(.))]" mode="copy"/>

  <!-- A leaf whose whole text is a separator, or is not text at all. The
       bar sat between an icon and a comment count; both went, and the bar
       stayed. -->
  <xsl:template match="*[not(*) and normalize-space(.) = '|']" mode="copy"/>
  <xsl:template match="text()[normalize-space(.) = '|']" mode="copy"/>
  <xsl:template match="*[not(*) and not(self::img) and not(self::br) and not(self::hr) and normalize-space(translate(., '&#160;', ' ')) = '']" mode="copy"/>

  <!-- A grid of cards is a list in the markup and a stream on the page.
       Read as a list it is a bullet holding a headline holding another
       list, indented away from the margin. Unwrap it: a card is a
       heading and a paragraph, and the bullets are left for the lists
       that are really lists. -->
  <xsl:template match="ul[li[.//h1 or .//h2 or .//h3 or .//h4 or .//h5 or .//h6]]|ol[li[.//h1 or .//h2 or .//h3 or .//h4 or .//h5 or .//h6]]" mode="copy">
    <xsl:apply-templates mode="copy"/>
  </xsl:template>
  <xsl:template match="li[.//h1 or .//h2 or .//h3 or .//h4 or .//h5 or .//h6]" mode="copy">
    <div><xsl:apply-templates mode="copy"/></div>
  </xsl:template>
</xsl:stylesheet>
