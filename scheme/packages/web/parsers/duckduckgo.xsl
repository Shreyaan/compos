<?xml version="1.0" encoding="UTF-8"?>
<!-- A search results page, calm: the results and nothing else.
     A result is a title, the site it is on, and a snippet. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <!-- No strip-space: the engine wraps matched words in <b>, and the
       spaces between those tags are whitespace-only text nodes. -->

  <xsl:template match="/">
    <html><body>
      <!-- the query is the page's title: without it the tab names
           itself after the first result -->
      <xsl:if test="//input[@name='q']">
        <h1><xsl:value-of select="//input[@name='q']/@value"/></h1>
      </xsl:if>
      <xsl:apply-templates select="//div[contains(@class, 'result__body')]"/>
      <xsl:apply-templates select="//div[contains(@class, 'nav-link')]"/>
    </body></html>
  </xsl:template>

  <!-- Next is a POST form. Its hidden fields as a query string are the
       next page, and a link is something the reader can follow. -->
  <xsl:template match="div[contains(@class, 'nav-link')]">
    <xsl:variable name="href">
      <xsl:text>/html/?</xsl:text>
      <xsl:for-each select=".//input[not(@type) or @type='hidden']">
        <xsl:if test="position() > 1"><xsl:text>&amp;</xsl:text></xsl:if>
        <xsl:value-of select="@name"/>
        <xsl:text>=</xsl:text>
        <xsl:value-of select="@value"/>
      </xsl:for-each>
    </xsl:variable>
    <p><a href="{$href}">Next</a></p>
  </xsl:template>

  <!-- copy-of, not value-of: value-of drops the <b> the engine wraps
       matched words in, and the words run together. -->
  <xsl:template match="div[contains(@class, 'result__body')]">
    <h2>
      <a href="{.//a[contains(@class, 'result__a')]/@href}">
        <xsl:copy-of select=".//a[contains(@class, 'result__a')]/node()"/>
      </a>
    </h2>
    <p><xsl:value-of select=".//a[contains(@class, 'result__url')]"/></p>
    <p><xsl:copy-of select=".//a[contains(@class, 'result__snippet')]/node()"/></p>
  </xsl:template>
</xsl:stylesheet>
