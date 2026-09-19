<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <html><body>
      <xsl:apply-templates select="//body" mode="copy"/>
    </body></html>
  </xsl:template>

  <xsl:template match="@*|node()" mode="copy">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" mode="copy"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="script|style|noscript" mode="copy"/>
  <xsl:template match="svg" mode="copy"/>
  <xsl:template match="img[starts-with(@src, 'data:')]" mode="copy"/>
  <xsl:template match="a[not(normalize-space(.))]" mode="copy"/>
  <xsl:template match="*[not(*) and normalize-space(.) = '|']" mode="copy"/>
  <xsl:template match="text()[normalize-space(.) = '|']" mode="copy"/>
  <xsl:template match="a[h1|h2|h3|h4|h5|h6]" mode="copy">
    <h2><a href="{@href}">
      <xsl:value-of select="normalize-space((h1|h2|h3|h4|h5|h6)[1])"/>
    </a></h2>
    <xsl:apply-templates mode="copy" select="node()[not(self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6)]"/>
  </xsl:template>

  <!-- div, 1407 chars, p=0.72; named by its footer -->
  <xsl:template match="footer" mode="copy"/>

  <!-- header #header, 1387 chars, p=0.87 -->
  <xsl:template match="header[@id='header']" mode="copy"/>

  <!-- div, 169 chars, p=0.66 -->
  <xsl:template match="div[contains(concat(' ', normalize-space(@class), ' '), ' patlok ')]" mode="copy"/>

  <!-- div, 13 chars, p=0.97 -->
  <xsl:template match="div[contains(concat(' ', normalize-space(@class), ' '), ' desktopadh ')]" mode="copy"/>

  <!-- div, 0 chars, p=0.55; named by its div; deletes 14 elements -->
  <xsl:template match="div[contains(concat(' ', normalize-space(@class), ' '), ' nw18-dfp-ad ')]" mode="copy"/>
</xsl:stylesheet>
