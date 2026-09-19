<?xml version="1.0" encoding="UTF-8"?>
<!-- discover.xsl - the page's structure as a table, for xslt.scm.

     Every other parser under this directory answers HTML. This one answers
     text: one line per structural element, with what a classifier needs to
     judge it and what a match pattern needs to address it.

       path|depth|tag|id|class|role|aria|chars|links|imgs|tagcount|tokens|sample

     depth counts from body's children. tokens lists each class token with
     the number of elements in the document that carry it: a token on one
     element addresses that element, a token on forty is a layout utility.

     The discovery pass and the parser it produces run in the same engine,
     so a pattern that selects a node here selects it in production.

     xslt.scm runs it: the html flag, a depth stringparam, this sheet, the
     page. An XML comment holds no double hyphen, so the command line is
     spelled out in words here.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8"/>
  <xsl:param name="depth" select="3"/>

  <xsl:template match="/">
    <xsl:apply-templates select="//body//*" mode="row"/>
  </xsl:template>

  <xsl:template match="script|style|noscript|link|meta|template" mode="row"/>

  <xsl:template match="*" mode="row">
    <xsl:variable name="d"
      select="count(ancestor::*) - count(ancestor::body/ancestor::*) - 1"/>
    <xsl:if test="$d &lt;= $depth">
      <xsl:for-each select="ancestor-or-self::*">
        <xsl:text>/</xsl:text>
        <xsl:value-of select="name()"/>
        <xsl:text>[</xsl:text>
        <xsl:value-of select="1 + count(preceding-sibling::*[name() = name(current())])"/>
        <xsl:text>]</xsl:text>
      </xsl:for-each>
      <xsl:text>|</xsl:text><xsl:value-of select="$d"/>
      <xsl:text>|</xsl:text><xsl:value-of select="name()"/>
      <xsl:text>|</xsl:text><xsl:call-template name="flat">
        <xsl:with-param name="s" select="@id"/></xsl:call-template>
      <xsl:text>|</xsl:text><xsl:call-template name="flat">
        <xsl:with-param name="s" select="@class"/></xsl:call-template>
      <xsl:text>|</xsl:text><xsl:call-template name="flat">
        <xsl:with-param name="s" select="@role"/></xsl:call-template>
      <xsl:text>|</xsl:text><xsl:call-template name="flat">
        <xsl:with-param name="s" select="@aria-label"/></xsl:call-template>
      <xsl:text>|</xsl:text><xsl:value-of select="string-length(normalize-space(.))"/>
      <xsl:text>|</xsl:text><xsl:value-of select="count(.//a)"/>
      <xsl:text>|</xsl:text><xsl:value-of select="count(.//img)"/>
      <xsl:text>|</xsl:text><xsl:value-of select="count(//*[name() = name(current())])"/>
      <xsl:text>|</xsl:text><xsl:call-template name="tokens">
        <xsl:with-param name="s" select="normalize-space(@class)"/></xsl:call-template>
      <xsl:text>|</xsl:text><xsl:call-template name="flat">
        <xsl:with-param name="s" select="substring(normalize-space(.), 1, 120)"/></xsl:call-template>
      <xsl:text>&#10;</xsl:text>
    </xsl:if>
  </xsl:template>

  <!-- a field holds no separator and no line break -->
  <xsl:template name="flat">
    <xsl:param name="s"/>
    <xsl:value-of select="translate($s, '|&#10;&#13;&#9;', '    ')"/>
  </xsl:template>

  <!-- XSLT 1.0 has no split, so the token walk recurses. Only the elements
       this pass reports pay for it. -->
  <xsl:template name="tokens">
    <xsl:param name="s"/>
    <xsl:if test="string-length($s) &gt; 0">
      <xsl:variable name="t" select="substring-before(concat($s, ' '), ' ')"/>
      <xsl:if test="string-length($t) &gt; 0">
        <xsl:value-of select="$t"/>
        <xsl:text>:</xsl:text>
        <xsl:value-of
          select="count(//*[contains(concat(' ', normalize-space(@class), ' '), concat(' ', $t, ' '))])"/>
        <xsl:text> </xsl:text>
      </xsl:if>
      <xsl:call-template name="tokens">
        <xsl:with-param name="s" select="normalize-space(substring-after($s, ' '))"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>
</xsl:stylesheet>
