<?xml version="1.0" encoding="UTF-8"?>
<!-- Amazon search results as records, not as a reading.

     The learner writes subtractive sheets: copy the page, delete the
     furniture. A listing needs the other kind, so this one is written by
     hand. It emits JSON, which json-parse turns into plists, so a row
     reaches the list as a record and the cells render it.

     The anchor is puis-card-container, NOT s-result-item. Amazon marks
     its ad carousels as s-result-item too: on one page, 24 s-result-item
     nodes were 16 products, 2 ad carousels, 3 labels, the facet rail,
     related searches and a help line. The card class is products only. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <!-- JSON string escaping: backslash first, then quote. -->
  <xsl:template name="esc-bs">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '\')">
        <xsl:value-of select="substring-before($s, '\')"/>
        <xsl:text>\\</xsl:text>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-after($s, '\')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="esc">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '&quot;')">
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-before($s, '&quot;')"/>
        </xsl:call-template>
        <xsl:text>\&quot;</xsl:text>
        <xsl:call-template name="esc">
          <xsl:with-param name="s" select="substring-after($s, '&quot;')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="$s"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="field">
    <xsl:param name="key"/>
    <xsl:param name="val"/>
    <xsl:text>&quot;</xsl:text>
    <xsl:value-of select="$key"/>
    <xsl:text>&quot;:&quot;</xsl:text>
    <xsl:call-template name="esc">
      <xsl:with-param name="s" select="normalize-space($val)"/>
    </xsl:call-template>
    <xsl:text>&quot;</xsl:text>
  </xsl:template>

  <xsl:template match="/">
    <xsl:text>[</xsl:text>
    <xsl:for-each select="//div[contains(concat(' ', @class, ' '), ' puis-card-container ')]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'asin'"/>
        <xsl:with-param name="val" select="ancestor::div[@data-asin][1]/@data-asin"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'title'"/>
        <xsl:with-param name="val" select=".//h2[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'image'"/>
        <xsl:with-param name="val" select=".//img[contains(@class,'s-image')][1]/@src"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'price'"/>
        <xsl:with-param name="val" select=".//span[@class='a-price-whole'][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'mrp'"/>
        <xsl:with-param name="val" select=".//span[contains(@class,'a-text-price')][1]//span[@class='a-offscreen'][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'rating'"/>
        <xsl:with-param name="val" select=".//span[@class='a-icon-alt'][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'reviews'"/>
        <xsl:with-param name="val" select=".//span[contains(@class,'a-size-mini')][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'delivery'"/>
        <xsl:with-param name="val" select=".//div[contains(@class,'udm-primary-delivery-message')][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'badge'"/>
        <xsl:with-param name="val" select=".//div[contains(@class,'udm-badge-block')][1]"/>
      </xsl:call-template>
      <xsl:text>}</xsl:text>
    </xsl:for-each>
    <xsl:text>]</xsl:text>
  </xsl:template>
</xsl:stylesheet>