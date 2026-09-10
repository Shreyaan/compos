<?xml version="1.0" encoding="UTF-8"?>
<!-- The recruiting queue as a document of blocks.

     The reading beside this one, web/parsers/svsrecruiting.xsl, writes
     html for pandoc. This one writes the document itself: a heading,
     the queues and their counts, and then ONE fenced block per
     application. The fence names the kind and the application id, so
     every verb in recruiting.scm has its target in the text and needs
     no table beside it.

     Five body lines, in the order a person reads a row: who, where it
     stands, the role, when it arrived, and what can be done. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8"/>

  <xsl:template match="/">
    <xsl:text># </xsl:text>
    <xsl:value-of select="normalize-space((//div[@id='staff-applications']//h1)[1])"/>
    <xsl:text>&#10;&#10;</xsl:text>

    <xsl:for-each select="//nav[contains(@class, 'app-tabstrip')]//a[contains(@class, 'app-tab')]">
      <xsl:if test="position() &gt; 1"><xsl:text> · </xsl:text></xsl:if>
      <xsl:value-of select="normalize-space(span[1])"/>
      <xsl:text> </xsl:text>
      <xsl:value-of select="normalize-space(span[contains(@class, 'app-tab-count')])"/>
      <xsl:if test="contains(@class, 'app-tab--active')"><xsl:text> (here)</xsl:text></xsl:if>
    </xsl:for-each>
    <xsl:text>&#10;&#10;</xsl:text>

    <xsl:value-of select="normalize-space((//div[@id='staff-applications']//p[contains(., 'sorted by')])[1])"/>
    <xsl:text>&#10;&#10;</xsl:text>

    <xsl:apply-templates select="//div[@id='staff-applications']//ol/li/article"/>
  </xsl:template>

  <xsl:template match="article">
    <xsl:variable name="mid" select="(.//div[contains(@class, 'flex-1')])[1]"/>
    <xsl:variable name="right" select="(.//div[contains(@class, 'md:text-right')])[1]"/>
    <xsl:variable name="name" select="(.//button[@phx-click = 'open_focus'])[1]"/>

    <xsl:text>```application </xsl:text>
    <xsl:value-of select="$name/@phx-value-id"/>
    <xsl:text>&#10;</xsl:text>

    <xsl:value-of select="normalize-space($name)"/>
    <xsl:if test=".//span[contains(., '★')]">
      <xsl:text>  </xsl:text>
      <xsl:value-of select="normalize-space((.//span[contains(., '★')])[1])"/>
    </xsl:if>
    <xsl:text>&#10;</xsl:text>

    <xsl:if test="normalize-space($mid/div[2]) != ''">
      <xsl:value-of select="normalize-space($mid/div[2])"/>
      <xsl:text>&#10;</xsl:text>
    </xsl:if>

    <xsl:if test="normalize-space($mid/div[contains(@class, 'text-sm')]) != ''">
      <xsl:value-of select="normalize-space($mid/div[contains(@class, 'text-sm')])"/>
      <xsl:text>&#10;</xsl:text>
    </xsl:if>

    <xsl:for-each select="$right//span[contains(., 'Applied')] | $right/div[contains(@class, 'ink-faint')]">
      <xsl:if test="position() &gt; 1"><xsl:text> · </xsl:text></xsl:if>
      <xsl:value-of select="normalize-space(.)"/>
    </xsl:for-each>
    <xsl:text>&#10;</xsl:text>

    <xsl:if test=".//button[@phx-click][not(@phx-click = 'open_focus')]">
      <xsl:for-each select=".//button[@phx-click][not(@phx-click = 'open_focus')]">
        <xsl:if test="position() &gt; 1"><xsl:text> · </xsl:text></xsl:if>
        <xsl:choose>
          <xsl:when test="text()[normalize-space()]">
            <xsl:value-of select="normalize-space((text()[normalize-space()])[1])"/>
          </xsl:when>
          <xsl:otherwise><xsl:value-of select="normalize-space(.)"/></xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
      <xsl:text>&#10;</xsl:text>
    </xsl:if>

    <xsl:text>```&#10;&#10;</xsl:text>
  </xsl:template>
</xsl:stylesheet>
