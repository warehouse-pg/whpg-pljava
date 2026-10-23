/*
 * Copyright (c) 2004-2015 Tada AB and other contributors, as listed below.
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the The BSD 3-Clause License
 * which accompanies this distribution, and is available at
 * http://opensource.org/licenses/BSD-3-Clause
 *
 * Contributors:
 *   Tada AB
 *   Purdue University
 */
package org.postgresql.pljava.internal;

import java.io.File;
import java.io.FilePermission;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.net.URLConnection;
import java.security.Permission;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.sql.SQLSyntaxErrorException;
import java.util.PropertyPermission;
import java.util.logging.Level;
import java.util.logging.Logger;

import org.postgresql.pljava.management.Commands;


/**
 * Provides access to some useful routines in the PostgreSQL server.
 * @author Thomas Hallgren
 */
public class Backend
{
	/**
	 * All native calls synchronize on this object.
	 */
	public static final Object THREADLOCK = new Object();

	private static Session s_session;

	public static synchronized Session getSession()
	{
		if(s_session == null)
			s_session = new Session();
		return s_session;
	}

	/**
	 * Returns the configuration option as read from the Global
	 * Unified Config package (GUC).
	 * @param key The name of the option.
	 * @return The value of the option.
	 */
	public static String getConfigOption(String key)
	{
		synchronized(THREADLOCK)
		{
			return _getConfigOption(key);
		}
	}

	/**
	 * returns the library path '$libdir'
	 */
	public static String getLibraryPath()
	{
		synchronized(THREADLOCK)
		{
			return _getLibraryPath();
		}
	}

	/**
	 * Returns the size of the statement cache.
	 * @return the size of the statement cache.
	 */
	public static int getStatementCacheSize()
	{
		synchronized(THREADLOCK)
		{
			return _getStatementCacheSize();
		}
	}

	/**
	 * Log a message using the internal elog command.
	 * @param logLevel The log level as defined in
	 * {@link ELogHandler}.
	 * @param str The message
	 */
	static void log(int logLevel, String str)
	{
		synchronized(THREADLOCK)
		{
			_log(logLevel, str);
		}
	}

	private static class PLJavaSecurityManager extends SecurityManager
	{
		private boolean m_recursion = false;

		public void checkPermission(Permission perm)
		{
			this.nonRecursiveCheck(perm);
		}

		public void checkPermission(Permission perm, Object context)
		{
			this.nonRecursiveCheck(perm);
		}

		private synchronized void nonRecursiveCheck(Permission perm)
		{
			if(m_recursion)
				//
				// Something, probably a ClassLoader
				// loading one of the referenced
				// classes, caused a recursion. Well
				// everything done within this method
				// is permitted so we just return
				// here.
				//
				return;

			m_recursion = true;
			try
			{
				this.assertPermission(perm);
			}
			finally
			{
				m_recursion = false;
			}
		}

		void assertPermission(Permission perm)
		{
			if(perm instanceof RuntimePermission)
			{
				String name = perm.getName();
				if("*".equals(name) || "exitVM".equals(name))
					throw new SecurityException();
				else if("setSecurityManager".equals(name) 
					&& !s_inSetTrusted)
					//
					// Attempt to set another
					// security manager while not
					// in the setTrusted method
					//
					throw new SecurityException();
			}
			else if(perm instanceof PropertyPermission)
			{
				if(perm.getActions().indexOf("write") >= 0)
				{
					// We never allow this to be changed.
					// As for UDT byteorder, the classes that use it only check
					// once so it would be misleading to allow runtime changes;
					// use pljava.vmoptions to provide an initial value.
					//
					String propName = perm.getName();
					if ( propName.equals("java.home") || propName.matches(
						"org\\.postgresql\\.pljava\\.udt\\.byteorder(?:\\..*)?")
					)
						throw new SecurityException();
				}
			}
		}
	}

	private static boolean s_inSetTrusted = false;

	private static final SecurityManager s_untrustedSecurityManager = new PLJavaSecurityManager();

	/**
	 * Returns <code>true</code> if any element of the path is "..".
	 */
	private static boolean hasDotDot(File f)
	{
		for ( ; f != null; f = f.getParentFile())
		{
			if ("..".equals(f.getName()))
				return true;
		}
		return false;
	}

	/**
	 * This security manager will block all attempts to access the file system
	 */
	private static final SecurityManager s_trustedSecurityManager = new PLJavaSecurityManager()
	{
		void assertPermission(Permission perm)
		{
			if(perm instanceof FilePermission)
			{
				String actions = perm.getActions();
				if("read".equals(actions))
				{
					// Allow read of /dev/random
					// and /dev/urandom

					String fileName = perm.getName();

					if ( "/dev/random".equals( fileName )
					     || 
					     "/dev/urandom".equals( fileName )
						)
						return;
					
					// Must be able to read
					// timezone info etc. in the
					// java installation
					// directory, and the jars in
					// $libdir/java and in
					// pljava_classpath.
					//
					// This check runs without THREADLOCK, and reading the
					// GUC enters the backend, so use the synchronized getter.
					String classpath = Backend.getConfigOption("pljava_classpath");
					String[] classpathArray = classpath.split(":");
					String jarpath =  Backend.getLibraryPath() + "/java";

					// With pljava_classpath_insecure any user can set
					// pljava_classpath, so then its entries grant no reads;
					// jars under $libdir/java are still covered.
					if (Backend._isClasspathInsecure())
						classpathArray = new String[0];

					File[] roots = new File[classpathArray.length + 2];
					roots[0] = new File(System.getProperty("java.home"));
					roots[1] = new File(jarpath);
					// relative entries are under $libdir/java, as in sqlj.Loader
					for (int i = 0; i < classpathArray.length; i++)
					{
						File classPathEntry = new File(classpathArray[i]);
						if (!classPathEntry.isAbsolute())
							classPathEntry = new File(jarpath, classpathArray[i]);
						roots[i + 2] = classPathEntry;
					}

					// A ".." in the name is resolved by the file system,
					// possibly through a symbolic link, so such a name is
					// only allowed if its canonical form is inside a
					// canonical root.
					//
					File accessedFile = new File(fileName);
					if (hasDotDot(accessedFile))
					{
						try
						{
							accessedFile = accessedFile.getCanonicalFile();
							for (int i = 0; i < roots.length; i++)
								roots[i] = roots[i].getCanonicalFile();
						}
						catch (IOException e)
						{
							throw new SecurityException(perm.getActions() + " on " + perm.getName());
						}
					}

					// the file itself may be a root, such as a jar named in
					// pljava_classpath
					for (File f = accessedFile; f != null; f = f.getParentFile())
					{
						for (int i = 0; i < roots.length; i++)
						{
							if (f.equals(roots[i]))
								return;
						}
					}
				}
				throw new SecurityException(perm.getActions() + " on " + perm.getName());
			}
			super.assertPermission(perm);
		}
	};

	public static void addClassImages(int jarId, String urlString)
	throws SQLException
	{
		// Opening the URL uses the server's file and network access, so
		// only a superuser may do it, however this method is reached.
		if(!AclId.getOuterUser().isSuperuser())
			throw new SQLSyntaxErrorException( // yeah, for 42501, really
				"Permission denied. Only a super user can install or " +
				"replace a jar from a URL", "42501");

		InputStream urlStream = null;
		boolean wasTrusted = (System.getSecurityManager() == s_trustedSecurityManager);

		if(wasTrusted)
			setTrusted(false);

		try
		{
			URL url = new URL(urlString);
			URLConnection uc = url.openConnection();
			uc.connect();
			int sz = uc.getContentLength(); // once java6 obsolete, use ...Long
			urlStream = uc.getInputStream();
			Commands.addClassImages(jarId, urlStream, sz);
		}
		catch(IOException e)
		{
			throw new SQLException("I/O exception reading jar file: " + e.getMessage());
		}
		finally
		{
			if(urlStream != null)
				try { urlStream.close(); } catch(IOException e) {}
			if(wasTrusted)
				setTrusted(true);
		}
	}

	public static void clearFunctionCache()
	{
		synchronized(THREADLOCK)
		{
			_clearFunctionCache();
		}
	}

	public static boolean isCreatingExtension()
	{
		synchronized(THREADLOCK)
		{
			return _isCreatingExtension();
		}
	}

	/**
	 * Called when the JVM is first booted and then everytime a switch
	 * is made between calling a trusted function versus an untrusted
	 * function.
	 */
	private static void setTrusted(boolean trusted)
	throws SQLException
	{
		SecurityManager mgr =
			trusted ? s_trustedSecurityManager : s_untrustedSecurityManager;
		s_inSetTrusted = true;
		try
		{
			Logger log = Logger.getAnonymousLogger();
			if(log.isLoggable(Level.FINE))
				log.fine("Using SecurityManager for " + (trusted ? "trusted" : "untrusted") + " language");
			System.setSecurityManager(mgr);
			if ( System.getSecurityManager() == mgr )
				return;
		}
		catch ( UnsupportedOperationException e ) { }
		finally
		{
			s_inSetTrusted = false;
		}
		if ( ! trusted )
			return;

		throw new SQLFeatureNotSupportedException(
			"PL/Java, when running on this version of Java, cannot " +
			"execute trusted functions. Possible solutions: (1) run Java 17 " +
			"or earlier; (2) on Java 18 through 23, add " +
			"-Djava.security.manager=allow to pljava_vmoptions; (3) " +
			"redeclare functions using the 'javau' (untrusted) PL/Java " +
			"language.", "0A000");
	}

	/**
	 * Returns <code>true</code> if the backend is awaiting a return from a
	 * call into the JVM. This method will only return <code>false</code>
	 * when called from a thread other then the main thread and the main
	 * thread has returned from the call into the JVM.
	 */
	public native static boolean isCallingJava();

	/**
	 * Returns the value of the GUC custom variable <code>
	 * pljava.release_lingering_savepoints</code>.
	 */
	public native static boolean isReleaseLingeringSavepoints();

	private native static String _getConfigOption(String key);
	private native static boolean _isClasspathInsecure();
	private native static String _getLibraryPath();

	private native static int  _getStatementCacheSize();
	private native static void _log(int logLevel, String str);
	private native static void _clearFunctionCache();
	private native static boolean _isCreatingExtension();
}
