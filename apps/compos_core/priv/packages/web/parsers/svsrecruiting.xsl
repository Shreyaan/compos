<?xml version="1.0" encoding="UTF-8"?>
<!-- SVS recruiting, calm: a staff queue as a list of decisions.

     The whole reading of /staff/applications gives 98 cards whose only
     visible text is an avatar image. The candidate name lives in the
     alt text and in a button that is not a link, so the reader draws a
     picture where a name belongs. What a person needs to act on a row,
     the status, the role, when it arrived and what the agent proposes,
     is spread over three columns and a footer strip.

     This reading gives ONE heading per application: the candidate,
     numbered, linked to the application page. Under it are the three
     lines that decide the row, and then the actions by name. The
     actions are named and not linked, because they are LiveView
     buttons and only the real browser can press one.

     Every other page of the site reads as its main element, with the
     reconnect toasts, the avatars and the scripts removed. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>

  <xsl:variable name="site" select="'https://svsrecruiting.com'"/>

  <!-- every href on this site is a path; the reader needs a whole URL -->
  <xsl:template name="abs">
    <xsl:param name="href"/>
    <xsl:choose>
      <xsl:when test="starts-with($href, 'http')">
        <xsl:value-of select="$href"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="concat($site, $href)"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="/">
    <html><body>
      <xsl:choose>
        <xsl:when test="//div[@id='staff-applications']">
          <xsl:apply-templates select="//div[@id='staff-applications']" mode="queue"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:apply-templates select="//main" mode="body"/>
        </xsl:otherwise>
      </xsl:choose>
    </body></html>
  </xsl:template>

  <!-- - - the queue - - - - - - - - - - - - - - - - - - - - - - - - - -->

  <xsl:template match="div[@id='staff-applications']" mode="queue">
    <h1><xsl:value-of select="normalize-space((.//h1)[1])"/></h1>
    <p><xsl:value-of select="normalize-space((.//div[contains(@class, 'app-note')])[1])"/></p>

    <!-- the queues as one line: each name, its count, and where you are -->
    <p>
      <xsl:for-each select=".//nav[contains(@class, 'app-tabstrip')]//a[contains(@class, 'app-tab')]">
        <xsl:if test="position() &gt; 1"><xsl:text> | </xsl:text></xsl:if>
        <a>
          <xsl:attribute name="href">
            <xsl:call-template name="abs">
              <xsl:with-param name="href" select="@href"/>
            </xsl:call-template>
          </xsl:attribute>
          <xsl:value-of select="normalize-space(span[1])"/>
          <xsl:text> </xsl:text>
          <xsl:value-of select="normalize-space(span[contains(@class, 'app-tab-count')])"/>
        </a>
        <xsl:if test="contains(@class, 'app-tab--active')"><xsl:text> (here)</xsl:text></xsl:if>
      </xsl:for-each>
    </p>

    <p><xsl:value-of select="normalize-space((.//p[contains(., 'sorted by')])[1])"/></p>

    <xsl:apply-templates select=".//ol/li/article" mode="card"/>
  </xsl:template>

  <!-- One application. The card is three columns and a footer strip;
       the reading is a heading and three lines. -->
  <xsl:template match="article" mode="card">
    <xsl:variable name="mid" select="(.//div[contains(@class, 'flex-1')])[1]"/>
    <xsl:variable name="right" select="(.//div[contains(@class, 'md:text-right')])[1]"/>
    <xsl:variable name="candidate" select="(.//a[contains(@href, '/staff/candidates/')])[1]/@href"/>
    <xsl:variable name="application" select="(.//a[contains(@href, '/staff/applications/')])[1]/@href"/>
    <xsl:variable name="meta" select="$right//span[contains(., 'Applied')] | $right/div[contains(@class, 'ink-faint')]"/>
    <xsl:variable name="buttons" select=".//button[@phx-click][not(@phx-click = 'open_focus')]"/>
    <xsl:variable name="target">
      <xsl:choose>
        <xsl:when test="$application"><xsl:value-of select="$application"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$candidate"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <h2>
      <xsl:value-of select="position()"/>
      <xsl:text>. </xsl:text>
      <a>
        <xsl:attribute name="href">
          <xsl:call-template name="abs">
            <xsl:with-param name="href" select="$target"/>
          </xsl:call-template>
        </xsl:attribute>
        <xsl:choose>
          <!-- the name is a quick-review button, never a link -->
          <xsl:when test=".//button[@phx-click = 'open_focus']">
            <xsl:value-of select="normalize-space((.//button[@phx-click = 'open_focus'])[1])"/>
          </xsl:when>
          <xsl:otherwise>
            <xsl:value-of select="normalize-space((.//img[@alt])[1]/@alt)"/>
          </xsl:otherwise>
        </xsl:choose>
      </a>
      <xsl:if test=".//span[contains(., '★')]">
        <xsl:text> </xsl:text>
        <xsl:value-of select="normalize-space((.//span[contains(., '★')])[1])"/>
      </xsl:if>
    </h2>

    <!-- where it stands, and what the agent has drafted about it -->
    <xsl:if test="normalize-space($mid/div[2]) != ''">
      <p><xsl:value-of select="normalize-space($mid/div[2])"/></p>
    </xsl:if>

    <!-- the role, with the job and the company still linked -->
    <xsl:if test="$mid/div[contains(@class, 'text-sm')]">
      <p><xsl:apply-templates select="$mid/div[contains(@class, 'text-sm')]/node()" mode="body"/></p>
    </xsl:if>

    <p>
      <xsl:for-each select="$meta">
        <xsl:if test="position() &gt; 1"><xsl:text> | </xsl:text></xsl:if>
        <xsl:value-of select="normalize-space(.)"/>
      </xsl:for-each>
      <xsl:if test="$candidate">
        <xsl:if test="$meta"><xsl:text> | </xsl:text></xsl:if>
        <a>
          <xsl:attribute name="href">
            <xsl:call-template name="abs">
              <xsl:with-param name="href" select="$candidate"/>
            </xsl:call-template>
          </xsl:attribute>
          <xsl:text>profile</xsl:text>
        </a>
      </xsl:if>
    </p>

    <!-- the footer strip and the snooze button, by name and by key -->
    <xsl:if test="$buttons">
      <p>
        <xsl:text>do: </xsl:text>
        <xsl:for-each select="$buttons">
          <xsl:if test="position() &gt; 1"><xsl:text>, </xsl:text></xsl:if>
          <xsl:choose>
            <xsl:when test="text()[normalize-space()]">
              <xsl:value-of select="normalize-space((text()[normalize-space()])[1])"/>
            </xsl:when>
            <xsl:otherwise>
              <xsl:value-of select="normalize-space(.)"/>
            </xsl:otherwise>
          </xsl:choose>
          <xsl:if test=".//span[contains(@class, 'abtn-kbd')]">
            <xsl:text> [</xsl:text>
            <xsl:value-of select="normalize-space((.//span[contains(@class, 'abtn-kbd')])[1])"/>
            <xsl:text>]</xsl:text>
          </xsl:if>
        </xsl:for-each>
      </p>
    </xsl:if>
  </xsl:template>

  <!-- - - every other page - - - - - - - - - - - - - - - - - - - - - -->

  <xsl:template match="@*|node()" mode="body">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" mode="body"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="a/@href" mode="body">
    <xsl:attribute name="href">
      <xsl:call-template name="abs">
        <xsl:with-param name="href" select="."/>
      </xsl:call-template>
    </xsl:attribute>
  </xsl:template>

  <xsl:template match="script|style|noscript|svg|template" mode="body"/>
  <xsl:template match="img[contains(@class, 'candidate-avatar')]" mode="body"/>

  <!-- the reconnect toasts are on every page and say nothing about it -->
  <xsl:template match="div[@id='flash-group']" mode="body"/>
</xsl:stylesheet>
